# Local UX verification

`ux-fixture-server.py` serves a small, disposable Subsonic library on loopback port 18992. It generates two WAV files, supports byte ranges and can slow or fail streams. No real Navidrome account is needed. Request logs omit query strings, including the fixture's fake authentication parameters.

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
  -only-testing:MinidiscUITests/MinidiscUXVerificationTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

Keep ad hoc code signing enabled: the simulated app writes its fixture credentials to Keychain, which requires its entitlements. Building with `CODE_SIGNING_ALLOWED=NO` fails that onboarding step.

Run `testOnboardingAccessibilityXXXL` separately on a fresh installation, before connecting the fixture account; it skips when onboarding has already been completed. Use the same command with `-only-testing:MinidiscUITests/MinidiscUXVerificationTests/testOnboardingAccessibilityXXXL`. The playback scenario can initialize the fixture account itself and does not depend on another test running first.

The scenarios connect to the fixture when needed and attach accessibility hierarchies to the test result. `UX_STEP` markers identify capture points. For a screenshot of a confirmed step, use `xcrun simctl io <simulator-UDID> screenshot <output.png>` through `rtk proxy`. Direct `simctl` capture avoids the screenshot timeout encountered with XCTest on the tested iOS 27 simulator.

These tests exercise visible controls and local fixture audio. They do not validate physical network handoffs, audio-route changes or iOS background scheduling over a long period. Stop the Python process when finished.
