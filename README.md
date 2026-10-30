# Pablo

Truck-aware navigation for heavy haul. Android only.

Pablo takes a destination from Towbook (or a pasted address), looks at which
unit the driver is in, computes a route for that combination's real
dimensions with Google's Large Vehicle Routing, then hands the route to
Google's own turn-by-turn inside the app. Reroutes keep the truck profile.

## How a driver uses it

1. Tap **Navigate** in Towbook (or share an address to Pablo, or paste it).
2. Pablo already knows the unit from last time. It routes and starts guidance.
3. Drive. If the unit or trailer changes, change it once on the home screen.

## One-time setup (owner)

### Google Cloud (account: info@towtruck.cv)

1. Create a Cloud project, enable billing.
2. Enable **Routes API**, **Navigation SDK**, **Maps SDK for Android**.
3. Submit the Large Vehicle Routing interest form:
   https://developers.google.com/maps/documentation/routes/contact
   Until Google provisions it, truck requests are refused and Pablo falls back
   to car routing with a red warning on screen.
4. Create an API key. Restrict it to Android apps: package `cv.towtruck.pablo`
   plus the signing SHA-1 shown in Pablo under **Units & settings**.
   Restrict APIs to the three above.

### GitHub secrets (Settings → Secrets and variables → Actions)

| Secret | Value |
| --- | --- |
| `MAPS_API_KEY` | the API key above |
| `KEYSTORE_BASE64` | base64 of the signing keystore (`base64 -w0 pablo.jks`) |
| `KEYSTORE_PASSWORD` | keystore password |
| `KEY_ALIAS` | key alias |
| `KEY_PASSWORD` | key password |

Without the keystore secrets the APK is debug-signed, which works for a first
install but every later build will refuse to install over it. Set them before
the second build.

### Install on a phone

Every push to `main` builds an APK and attaches it to a GitHub Release
(`build-N`). On the phone: open the release, download the `.apk`, open it,
allow installs from the browser when asked.

### Make Pablo the default from Towbook

Towbook hands off a destination the same way every app does. First time, Android
asks which app should open it; pick Pablo and **Always**. If Towbook opens
Google Maps directly with no prompt, use the share sheet instead: share the
address to Pablo. Both paths land on the same screen.

For Google Maps web links (`maps.google.com`, `maps.app.goo.gl`) Android 12+
also needs **Settings → Apps → Pablo → Open by default → Add link**.

## Fleet data

`assets/profiles.json` holds tractors, trailers and light units. Dimensions
are millimeters and kilograms. Anything marked `estimated` is a placeholder
until it is checked against the annual permit. Numbers edited in the app under
**Units & settings** override the file on that phone without a rebuild.

A combination is computed, not stored:

- axles = tractor axles + trailer axles
- length = tractor bumper-to-kingpin + trailer length
- height, width = larger of tractor and trailer permit envelope
- gross weight = trailer permit gross

Light units route in DRIVE mode (as a car). Tractors route in TRUCK mode.

`assets/hazards.json` is the local-knowledge layer Google does not have:
low bridges, no-truck roads, frost-law roads, construction width limits.
Pablo warns when a computed route passes through one. Shipped empty.

## Build locally

```
flutter pub get
flutter build apk --release --dart-define=MAPS_API_KEY=your_key
```

Requires Flutter 3.44+, JDK 17.
