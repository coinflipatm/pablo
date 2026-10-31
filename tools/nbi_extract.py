"""Pull Michigan's National Bridge Inventory and extract truck hazards.

Outputs (data/bridges/):
  status.txt          which source file was used, column names, row counts
  low_clearance.csv   every MI structure with a vertical clearance under 14'6"
  posted.csv          bridges posted, restricted, or closed (item 41)
  summary.md          counts by county
"""
import csv, io, os, sys, urllib.request, zipfile

OUT = "data/bridges"
os.makedirs(OUT, exist_ok=True)
WARN_M = 4.42   # 14'6"
HARD_M = 4.115  # 13'6" (Michigan legal max height)

URLS = [
    f"https://www.fhwa.dot.gov/bridge/nbi/{y}/delimited/MI{str(y)[2:]}.{ext}"
    for y in (2025, 2024, 2023) for ext in ("txt", "zip")
]
COUNTIES = {
    "011": "Arenac", "017": "Bay", "035": "Clare", "037": "Clinton", "045": "Eaton",
    "049": "Genesee", "051": "Gladwin", "057": "Gratiot", "063": "Huron", "065": "Ingham",
    "073": "Isabella", "075": "Jackson", "081": "Kent", "087": "Lapeer", "093": "Livingston",
    "097": "Mackinac", "099": "Macomb", "111": "Midland", "115": "Monroe", "125": "Oakland",
    "137": "Otsego", "145": "Saginaw", "147": "St. Clair", "151": "Sanilac",
    "155": "Shiawassee", "157": "Tuscola", "161": "Washtenaw", "163": "Wayne",
}
POSTED = {"B": "posting recommended", "P": "posted for load", "R": "restricted",
          "K": "CLOSED", "D": "temp shoring", "E": "temp structure"}

status = []
raw = None
for url in URLS:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 pablo-nbi"})
        data = urllib.request.urlopen(req, timeout=120).read()
        if url.endswith(".zip"):
            z = zipfile.ZipFile(io.BytesIO(data))
            data = z.read(z.namelist()[0])
        raw = data.decode("latin-1")
        status.append(f"source: {url} ({len(data)} bytes)")
        break
    except Exception as e:
        status.append(f"failed: {url} -> {e}")

def done(lines):
    open(f"{OUT}/status.txt", "w").write("\n".join(lines) + "\n")

if raw is None:
    done(status); sys.exit(0)

rows = list(csv.DictReader(io.StringIO(raw), quotechar="'"))
cols = list(rows[0].keys()) if rows else []
status.append(f"rows: {len(rows)}")
status.append("columns: " + ", ".join(cols))

def col(suffix):
    for c in cols:
        if c.strip().upper().endswith(suffix):
            return c
    return None

C = {k: col(s) for k, s in {
    "struct": "_008", "rtype": "_005A", "county": "_003", "feat": "_006A",
    "carried": "_007", "loc": "_009", "clr10": "_010", "lat": "_016", "lon": "_017",
    "posted": "_041", "und_ref": "_054A", "und": "_054B", "year": "_027",
}.items()}
status.append("mapped: " + ", ".join(f"{k}={v}" for k, v in C.items()))

def g(r, k):
    c = C.get(k)
    return (r.get(c) or "").strip().strip("'").strip() if c else ""

def meters(v):
    try:
        x = float(v)
    except ValueError:
        return None
    if x > 100:   # fixed-width style XXXX = XX.XX m
        x /= 100
    return None if x <= 0 or x >= 99 else x

def dms(v, lon):
    v = v.strip()
    if not v.isdigit() or int(v) == 0:
        return None
    v = v.zfill(9 if lon else 8)
    d = int(v[:3] if lon else v[:2]); rest = v[3:] if lon else v[2:]
    val = d + int(rest[:2]) / 60 + int(rest[2:]) / 100 / 3600
    return -val if lon else val

def ftin(m):
    inches = round(m / 0.0254)
    return f"{inches // 12}'{inches % 12}\""

low, posted = [], []
for r in rows:
    lat, lon = dms(g(r, "lat"), False), dms(g(r, "lon"), True)
    if lat is None or lon is None:
        continue
    base = dict(structure=g(r, "struct"), county=g(r, "county").zfill(3),
                carried=g(r, "carried"), under=g(r, "feat"), location=g(r, "loc"),
                year=g(r, "year"), lat=round(lat, 6), lng=round(lon, 6))
    rtype = g(r, "rtype")
    c10 = meters(g(r, "clr10"))
    if c10 is not None and c10 < WARN_M:
        # Record type 1: clearance on the road the bridge carries (e.g. truss).
        # Other types: clearance for the inventory route passing UNDER it.
        applies = base["carried"] if rtype == "1" else base["under"]
        low.append({**base, "source": "item10", "applies_to": applies,
                    "clearance_m": round(c10, 2), "clearance": ftin(c10),
                    "hard_stop": c10 < HARD_M})
    if rtype == "1" and g(r, "und_ref") == "H":
        c54 = meters(g(r, "und"))
        if c54 is not None and c54 < WARN_M:
            low.append({**base, "source": "item54", "applies_to": base["under"],
                        "clearance_m": round(c54, 2), "clearance": ftin(c54),
                        "hard_stop": c54 < HARD_M})
    p = g(r, "posted")
    if rtype == "1" and p in POSTED:
        posted.append({**base, "status": POSTED[p], "applies_to": base["carried"]})

# Same physical clearance can appear as both item 10 and item 54; keep the lowest per structure+road.
best = {}
for h in low:
    k = (h["structure"], h["applies_to"])
    if k not in best or h["clearance_m"] < best[k]["clearance_m"]:
        best[k] = h
low = sorted(best.values(), key=lambda h: (h["county"], h["clearance_m"]))

def write(name, items):
    if not items:
        open(f"{OUT}/{name}", "w").write(""); return
    keys = list(items[0].keys())
    with open(f"{OUT}/{name}", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys); w.writeheader(); w.writerows(items)

write("low_clearance.csv", low)
write("posted.csv", posted)

by = {}
for h in low:
    e = by.setdefault(h["county"], [0, 0, 0]); e[0] += 1; e[1] += h["hard_stop"]
for p in posted:
    by.setdefault(p["county"], [0, 0, 0])[2] += 1
lines = ["| County | Under 14'6\" | Under 13'6\" | Posted/closed |", "|---|---|---|---|"]
for code, (n, hard, pc) in sorted(by.items(), key=lambda kv: -kv[1][0]):
    lines.append(f"| {COUNTIES.get(code, code)} | {n} | {hard} | {pc} |")
open(f"{OUT}/summary.md", "w").write("\n".join(lines) + "\n")
status.append(f"low clearance (<14'6\"): {len(low)}; posted/closed: {len(posted)}")
done(status)
