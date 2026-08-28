# Release checks

Run `Scripts/doctor.sh --strict --build` before archiving a release, then verify
the signed archive and Xcode's merged privacy report on a physical device.

## Privacy contract

`Minidisc/PrivacyInfo.xcprivacy` declares the app's current required-reason APIs:

- `UserDefaults` stores app-only preferences (`CA92.1`).
- File timestamps and metadata are read only for files inside the app container
  (`C617.1`), primarily to validate and evict cached artwork.

Minidisc does not track users. When the user explicitly enables ListenBrainz,
the app can send their ListenBrainz account identifier and music listening data
for scrobbling, recommendations, and other requested service functionality.
Those linked data categories are declared without tracking.

When the lyrics source is `Auto` or `LRCLIB`, Minidisc can send a track's title,
artist, album, and duration to `https://lrclib.net` to retrieve lyrics. Requests
never include server credentials, custom headers, server identifiers, or the
server's URL. Before release, verify this disclosure against LRCLIB's current
data practices and Xcode's merged privacy report.

Re-audit the manifest whenever app code or a dependency adds analytics,
diagnostics, identifiers, filesystem metadata, advertising, or data collection.

## Network transport

`NSAllowsArbitraryLoads` is intentional. Minidisc connects to user-configured,
self-hosted Subsonic servers, including HTTP-only installations on private
networks. Removing the exception would silently break that supported setup.
Credentials and custom headers must still be scoped to the configured server;
new first-party or third-party endpoints should use HTTPS.

## Manual release validation

- Build and archive with the Release configuration.
- Inspect Xcode's merged privacy report, including SwiftSonic.
- Install the signed archive on a physical device.
- Verify foreground and background playback.
- Verify transitions between Wi-Fi and cellular data.
- Verify an HTTPS server and, when supported for the release, an HTTP server.
- Run unit tests; UI tests remain a separate manual validation step.
