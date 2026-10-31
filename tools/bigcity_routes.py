"""Big City call routes vs. Michigan bridge hazards.

Input  (decrypted by the workflow): work/addresses.csv  (street,city,zip,label,calls_count,...,call_numbers)
Bridge data: data/bridges/low_clearance.csv, data/bridges/posted.csv
Output: work/out/*  (encrypted by the workflow before commit; addresses never land in the repo in clear)
        data/bigcity/status.txt  (counts only, public)
"""
import csv, io, json, math, os, re, subprocess, sys, time, urllib.request, zipfile

WORK, OUT, PUB = "work", "work/out", "data/bigcity"
for d in (OUT, PUB):
    os.makedirs(d, exist_ok=True)
UA = {"User-Agent": "pablo-route-audit/1.0 (github.com/coinflipatm/pablo)"}
NEAR_M = 40          # route must pass this close to a bridge point to be considered
LAST_MILE_M = 1500   # hazards this close to a job address are listed for that address
status = []

def log(s):
    print(s, flush=True); status.append(s)

# ---------- geometry ----------
def dist_m(a, b):
    (la1, lo1), (la2, lo2) = a, b
    x = math.radians(lo2 - lo1) * math.cos(math.radians((la1 + la2) / 2))
    y = math.radians(la2 - la1)
    return 6371000 * math.hypot(x, y)

def point_seg_m(p, a, b):
    """Distance from p to segment a-b, all (lat,lng); local planar approx."""
    k = math.cos(math.radians(p[0]))
    ax, ay = (a[1] - p[1]) * k, a[0] - p[0]
    bx, by = (b[1] - p[1]) * k, b[0] - p[0]
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    t = 0 if L == 0 else max(0, min(1, -(ax * dx + ay * dy) / L))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(cx, cy) * 111195

# ---------- road-name matching ----------
DROP = set("ST STREET RD ROAD AVE AV AVENUE DR DRIVE BLVD BOULEVARD HWY HIGHWAY PKWY PARKWAY CT LN LANE "
           "TRL TRAIL WAY N S E W NB SB EB WB NORTH SOUTH EAST WEST OLD THE OF AND TO ON RMP RAMP "
           "SERVICE BUS BR FWY FREEWAY EXPY EXPRESSWAY".split())

EXPAND = {"N": "NORTH", "S": "SOUTH", "E": "EAST", "W": "WEST", "BLVD": "BOULEVARD", "AVE": "AVENUE",
          "ST": "STREET", "RD": "ROAD", "DR": "DRIVE"}

def norm_tokens(s):
    s = (s or "").upper().replace("INTERSTATE", "I")
    s = re.sub(r"\b(I|US|M)[\s\-]*(\d+)[A-Z]?\b", r"\1\2", s)   # I-75 / I 75 / I475S -> I75 / I475
    s = re.sub(r"[^A-Z0-9 ]", " ", s)
    words = [EXPAND.get(t, t) for t in s.split()]
    core = {t for t in words if t not in DROP and len(t) > 1}
    # A name made only of generic words ("W Boulevard") keeps them all.
    return core or set(words)

def names_match(applies_to, step_names):
    parts = [p for p in re.split(r"[;,/&]", applies_to or "") if p.strip()]
    step_tok = [norm_tokens(n) for n in step_names if n]
    for p in parts:
        a = norm_tokens(p)
        if not a:
            continue
        for s in step_tok:
            if s and (a <= s or s <= a):
                return True
    return False

def selftest():
    assert names_match("COURT ST", ["Court Street"])
    assert names_match("I-75", ["Chrysler Freeway", "I 75"])
    assert names_match("I-475S ON RMP C", ["I 475"])
    assert names_match("W BOULEVARD; FLINT RIVER", ["West Boulevard"])
    assert not names_match("COURT ST", ["I 75", "Chrysler Freeway"])
    assert not names_match("ELMS RD", ["I 69"])
    assert names_match("US-23", ["US 23"])
    assert not names_match("US-23", ["US 223"])
    assert abs(point_seg_m((43.0, -83.7), (43.0, -83.701), (43.0, -83.699)) ) < 1
    print("selftest ok")

if len(sys.argv) > 1 and sys.argv[1] == "selftest":
    selftest(); sys.exit(0)

# ---------- load inputs ----------
rows = list(csv.DictReader(open(f"{WORK}/addresses.csv", newline="")))
for i, r in enumerate(rows):
    r["id"] = str(i)
log(f"addresses: {len(rows)}")

# ---------- geocode (US Census batch, free, no key) ----------
batch = io.StringIO()
w = csv.writer(batch)
for r in rows:
    w.writerow([r["id"], r["street"].strip(), r["city"].strip(), "MI", r["zip"].strip()])
open(f"{WORK}/batch.csv", "w").write(batch.getvalue())
geo = {}
for attempt in range(3):
    res = subprocess.run(["curl", "-sS", "--max-time", "900", "--form", f"addressFile=@{WORK}/batch.csv",
                          "--form", "benchmark=Public_AR_Current",
                          "https://geocoding.geo.census.gov/geocoder/locations/addressbatch"],
                         capture_output=True, text=True)
    if res.returncode == 0 and res.stdout.strip():
        for rec in csv.reader(io.StringIO(res.stdout)):
            if len(rec) >= 6 and rec[2] == "Match" and "," in rec[5]:
                lon, lat = (float(x) for x in rec[5].split(","))
                geo[rec[0]] = (lat, lon, "address")
        break
    log(f"census attempt {attempt+1} failed: {res.stderr[:200]}")
    time.sleep(10)
log(f"geocoded exact/near address: {len(geo)}")

# ZIP-centroid fallback for anything the Census geocoder couldn't place.
zc = {}
for y in (2024, 2023, 2022):
    try:
        url = f"https://www2.census.gov/geo/docs/maps-data/data/gazetteer/{y}_Gazetteer/{y}_Gaz_zcta_national.zip"
        z = zipfile.ZipFile(io.BytesIO(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120).read()))
        txt = z.read(z.namelist()[0]).decode("latin-1")
        rd = csv.reader(io.StringIO(txt), delimiter="\t")
        hdr = [h.strip() for h in next(rd)]
        gi, la, lo = hdr.index("GEOID"), hdr.index("INTPTLAT"), hdr.index("INTPTLONG")
        for rec in rd:
            zc[rec[gi].strip()] = (float(rec[la]), float(rec[lo]))
        log(f"zip centroids: {y} ({len(zc)})"); break
    except Exception as e:
        log(f"zip gazetteer {y} failed: {e}")
fallback = 0
for r in rows:
    if r["id"] not in geo and r["zip"].strip()[:5] in zc:
        lat, lon = zc[r["zip"].strip()[:5]]
        geo[r["id"]] = (lat, lon, "zip"); fallback += 1
log(f"zip-centroid fallback: {fallback}; unplaced: {len(rows) - len(geo)}")

# ---------- calls = pairs of stops ----------
stops_by_call = {}
for r in rows:
    for c in r["call_numbers"].split():
        stops_by_call.setdefault(c, []).append(r["id"])
pairs = {}
for c, ids in stops_by_call.items():
    if len(ids) == 2 and ids[0] in geo and ids[1] in geo and ids[0] != ids[1]:
        key = tuple(sorted(ids))
        pairs.setdefault(key, []).append(c)
log(f"calls with two placed stops: {sum(len(v) for v in pairs.values())}; unique stop pairs: {len(pairs)}")

# ---------- bridges in the service area ----------
lats = [g[0] for g in geo.values()]; lngs = [g[1] for g in geo.values()]
m = 0.15
bbox = (min(lats) - m, max(lats) + m, min(lngs) - m, max(lngs) + m)
def in_box(la, lo):
    return bbox[0] <= la <= bbox[1] and bbox[2] <= lo <= bbox[3]
low = [b for b in csv.DictReader(open("data/bridges/low_clearance.csv")) if in_box(float(b["lat"]), float(b["lng"]))]
posted = [b for b in csv.DictReader(open("data/bridges/posted.csv")) if in_box(float(b["lat"]), float(b["lng"]))]
for b in low + posted:
    b["pt"] = (float(b["lat"]), float(b["lng"]))
log(f"service-area box {tuple(round(x,3) for x in bbox)}: low-clearance {len(low)}, posted/closed {len(posted)}")

# ---------- route each pair (OSRM public demo, car profile, ~1 req/s) ----------
def osrm(a, b):
    url = (f"https://router.project-osrm.org/route/v1/driving/{a[1]:.6f},{a[0]:.6f};{b[1]:.6f},{b[0]:.6f}"
           "?overview=full&geometries=geojson&steps=true")
    for attempt in range(3):
        try:
            d = json.load(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30))
            if d.get("code") == "Ok":
                return d["routes"][0]
            return None
        except Exception:
            time.sleep(3 * (attempt + 1))
    return None

low_hits, posted_hits = {}, {}
route_lines, failed = [], 0
t0 = time.time()
for n, (key, calls) in enumerate(pairs.items()):
    a, b = geo[key[0]][:2], geo[key[1]][:2]
    rt = osrm(a, b)
    time.sleep(1.0)
    if rt is None:
        failed += 1; continue
    steps = []
    for leg in rt["legs"]:
        for s in leg["steps"]:
            pts = [(c[1], c[0]) for c in s["geometry"]["coordinates"]]
            steps.append(((s.get("name") or ""), (s.get("ref") or ""), pts))
    allpts = [(c[1], c[0]) for c in rt["geometry"]["coordinates"]]
    route_lines.append({"calls": calls, "miles": round(rt["distance"] / 1609.344, 1),
                        "coords": [[round(p[1], 5), round(p[0], 5)] for p in allpts[::4] + allpts[-1:]]})
    rla = [p[0] for p in allpts]; rlo = [p[1] for p in allpts]
    rbox = (min(rla) - 0.001, max(rla) + 0.001, min(rlo) - 0.0015, max(rlo) + 0.0015)
    for pool, hits in ((low, low_hits), (posted, posted_hits)):
        for br in pool:
            la, lo = br["pt"]
            if not (rbox[0] <= la <= rbox[1] and rbox[2] <= lo <= rbox[3]):
                continue
            near_names = []
            for name, ref, pts in steps:
                if any(point_seg_m(br["pt"], pts[i], pts[i + 1]) <= NEAR_M for i in range(len(pts) - 1)) or \
                   (len(pts) == 1 and dist_m(br["pt"], pts[0]) <= NEAR_M):
                    near_names += [name] + ref.split(";")
            if not near_names:
                continue
            k = (br["structure"], br["applies_to"])
            e = hits.setdefault(k, {"bridge": br, "calls": [], "nearby_only": []})
            (e["calls"] if names_match(br["applies_to"], near_names) else e["nearby_only"]).extend(calls)
    if n % 100 == 0:
        print(f"routed {n}/{len(pairs)} in {int(time.time()-t0)}s", flush=True)
log(f"routed: {len(pairs) - failed}; routing failures: {failed}")

# ---------- outputs ----------
def ft(b):
    return b.get("clearance", "")

with open(f"{OUT}/low_clearance_hits.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["clearance", "hard_stop_under_13_6", "road_affected", "bridge_carries", "location", "county",
                "calls_routed_under", "calls_passing_nearby_other_road", "lat", "lng", "structure", "call_numbers"])
    for k, e in sorted(low_hits.items(), key=lambda kv: (-len(set(kv[1]["calls"])), float(kv[1]["bridge"]["clearance_m"]))):
        b = e["bridge"]
        w.writerow([ft(b), b["hard_stop"], b["applies_to"], b["carried"], b["location"], b["county"],
                    len(set(e["calls"])), len(set(e["nearby_only"])), b["lat"], b["lng"], b["structure"],
                    " ".join(sorted(set(e["calls"])))])
with open(f"{OUT}/posted_hits.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["status", "road_on_bridge", "crosses", "location", "county", "calls_routed_over",
                "lat", "lng", "structure", "call_numbers"])
    for k, e in sorted(posted_hits.items(), key=lambda kv: -len(set(kv[1]["calls"]))):
        if not e["calls"]:
            continue
        b = e["bridge"]
        w.writerow([b["status"], b["applies_to"], b["under"], b["location"], b["county"], len(set(e["calls"])),
                    b["lat"], b["lng"], b["structure"], " ".join(sorted(set(e["calls"])))])

with open(f"{OUT}/last_mile.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["street", "city", "label", "calls_count", "placed_by", "hazard", "detail", "road_affected", "meters_away"])
    for r in rows:
        g = geo.get(r["id"])
        if not g:
            continue
        for b in low:
            d = dist_m(g[:2], b["pt"])
            if d <= LAST_MILE_M:
                w.writerow([r["street"], r["city"], r["label"], r["calls_count"], g[2], "low clearance",
                            b["clearance"], b["applies_to"], int(d)])
        for b in posted:
            d = dist_m(g[:2], b["pt"])
            if d <= LAST_MILE_M:
                w.writerow([r["street"], r["city"], r["label"], r["calls_count"], g[2], b["status"],
                            b["under"], b["applies_to"], int(d)])

with open(f"{OUT}/geocoded.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["street", "city", "zip", "label", "calls_count", "lat", "lng", "placed_by"])
    for r in rows:
        g = geo.get(r["id"])
        w.writerow([r["street"], r["city"], r["zip"], r["label"], r["calls_count"],
                    g[0] if g else "", g[1] if g else "", g[2] if g else "unplaced"])
json.dump({"bbox": bbox, "routes": route_lines}, open(f"{OUT}/routes.json", "w"))

n_low = sum(1 for e in low_hits.values() if e["calls"])
n_post = sum(1 for e in posted_hits.values() if e["calls"])
calls_low = len({c for e in low_hits.values() for c in e["calls"]})
log(f"low-clearance bridges a call was routed under: {n_low} (calls affected: {calls_low})")
log(f"posted/closed bridges a call was routed over: {n_post}")
open(f"{PUB}/status.txt", "w").write("\n".join(status) + "\n")
