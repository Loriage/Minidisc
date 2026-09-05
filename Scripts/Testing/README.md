# Local UX verification

`ux-fixture-server.py` serves a small, disposable Subsonic library on loopback port 18992. It generates silent WAV audio, supports byte ranges and can slow or fail streams. No real Navidrome account is needed. Request logs omit query strings, including the fixture's fake authentication parameters.

Create a fresh iOS Simulator named **Minidisc UX Verification** in Xcode's Devices and Simulators window. Keep it dedicated to this fixture; the UI tests deliberately skip other simulators and physical devices. Do not configure a real server in it.

From the repository root, start the fixture and leave it running:

```sh
rtk proxy python3 Scripts/Testing/ux-fixture-server.py
```

In another terminal, run the opt-in UI scenarios:

```sh
rtk proxy xcodebuild test \
  -project Minidisc.xcodeproj \
  -scheme MinidiscUITests \
  -destination 'platform=iOS Simulator,name=Minidisc UX Verification' \
  -derivedDataPath /tmp/minidisc-ux-tests \
  -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -only-testing:MinidiscUITests/MinidiscUXVerificationTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

Keep ad hoc code signing enabled: the simulated app writes its fixture credentials to Keychain, which requires its entitlements. Building with `CODE_SIGNING_ALLOWED=NO` fails that onboarding step.

Run `testOnboardingAccessibilityXXXL` separately on a fresh installation, before connecting the fixture account; it skips when onboarding has already been completed. Use the same command with `-only-testing:MinidiscUITests/MinidiscUXVerificationTests/testOnboardingAccessibilityXXXL`. The playback scenario can initialize the fixture account itself and does not depend on another test running first.

The scenarios connect to the fixture when needed and attach accessibility hierarchies to the test result. `UX_STEP` markers identify capture points. For a screenshot of a confirmed step, use `xcrun simctl io <simulator-UDID> screenshot <output.png>` through `rtk proxy`. Direct `simctl` capture avoids the screenshot timeout encountered with XCTest on the tested iOS 27 simulator.

The everyday listening scenarios cover ranked search and category filters, playlist navigation with a
preserved query, queue removal/Undo/reordering, saving the queue, grouped additions to existing and new
playlists, and personalized Home with large text. Add `-only-testing` for one named method in
`MinidiscUXVerificationTests` to rerun a specific flow.

The fixture provides separate `search_catalog`, `queue_catalog` and `home_catalog` modes. Queue audio
lasts two minutes to keep playback active during edits. Home includes favorites, recently played,
frequent albums and recent library additions from familiar and unrelated artists. Search intentionally
returns a prefix title before its exact match, so the UI must apply its own ranking.

The refinement scenarios add Home playlist priority, an immediately visible Search field, selection
inside result headings, inline browse titles, alphabet jumps in lists and grids, and functional artist
stations/Smart Shuffle. `browse_catalog` provides 24 tracks with distinct albums and artists under
A, É, Z and #, plus a downloadable playlist. The Downloads probe uses those actual local fixture files.
An album favorite under H and the additional Iris Ensemble artist under I verify jumps into the
other Favorites categories, whose anchors must remain distinct from song IDs.
`GET /__requests` retains a bounded journal of synthetic endpoint names and IDs to verify artist seeds;
it records no authentication fields or full URLs. Reset it with `reset_requests: true`.

Catalogue modes also update the fixture scan timestamp. The relevant probes pull to refresh Songs,
Albums or Artists through the visible UI before asserting their mode-specific records, because a
completed persistent index can otherwise retain a preceding scenario's catalogue. Sort and layout
preferences are changed through their native controls; launch-argument defaults would override the
same settings that the buttons are supposed to change.

Tests reset synthetic playlist mutations through `POST /__state` with `reset_playlists: true` and verify
the resulting ordered track IDs through `GET /__mutations`. These endpoints affect only the in-memory
fixture. Each scenario sets its catalog mode and checks the fixture marker before interacting with
playlist controls. A skipped scenario means the isolated fixture was unavailable; it is not a passing
verification.

These tests exercise visible controls and local fixture audio. They do not validate physical network handoffs, audio-route changes or iOS background scheduling over a long period. Stop the Python process when finished.
