# iOS TestFlight release

- App Store Connect app: `Pc remote console` (`6833300906`)
- Bundle ID: `app.pccontrol.remote`
- Marketing version: `1.0.0`
- TestFlight build: `5.1`
- Source commit: `e278a5260826adeb92a9f9dc428085ec3556fab7`
- Remote build: [GitHub Actions run 42959271697](https://github.com/stormey2010/pc-control/actions/runs/42959271697)
- Result: Xcode archive and Apple Distribution signing succeeded; App Store Connect accepted the upload and processed it as `VALID`.
- TestFlight: build is in the existing internal `Team` group. That group has access to all eligible builds and currently has one tester.
- Automated tests: none were run, as requested.

Open [TestFlight in App Store Connect](https://appstoreconnect.apple.com/apps/6833300906/testflight/ios) to manage internal access. The uploaded build is available to members of the `Team` group after TestFlight refreshes on their devices.

## Pair a phone with the PC

The Windows agent runs in the background from startup. On the same Wi-Fi:

1. Open the iOS app and allow Local Network access.
2. Tap your PC under Nearby Computers.
3. Enter the four-digit code that automatically appears on the PC, then tap Connect.

The code window closes when pairing succeeds. The app saves the credential and certificate pin in Keychain and reconnects automatically on later launches. Codes expire after two minutes; request a new code if necessary.

Existing QR pairing remains under Other ways to connect. Existing paired phones keep working; re-pairing is optional.

This update fixes the previous JSON frame error. The iOS sender uses text WebSocket frames; the agent also accepts binary JSON frames for compatibility with the first build.

The workflow is manual-dispatch only. To create a later TestFlight build, run **Build iOS and upload to TestFlight** from the repository's GitHub Actions page. It archives and signs on GitHub's macOS runner and does not run tests.
