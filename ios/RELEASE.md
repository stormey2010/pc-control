# iOS TestFlight release

- App Store Connect app: `Pc remote console` (`6833300906`)
- Bundle ID: `app.pccontrol.remote`
- Marketing version: `1.0.0`
- TestFlight build: `3.1`
- Source commit: `e489781516f3e9ef84678cafea5de30eeab95994`
- Remote build: [GitHub Actions run 42957731043](https://github.com/stormey2010/pc-control/actions/runs/42957731043)
- Result: Xcode archive and Apple Distribution signing succeeded; App Store Connect accepted the upload and processed it as `VALID`.
- TestFlight: build is in the existing internal `Team` group. That group has access to all eligible builds and currently has one tester.
- Automated tests: none were run, as requested.

Open [TestFlight in App Store Connect](https://appstoreconnect.apple.com/apps/6833300906/testflight/ios) to manage internal access. The uploaded build is available to members of the `Team` group after TestFlight refreshes on their devices.

## Pair a phone with the PC

The Windows agent runs in the background from startup. From this repository on the PC, run:

```powershell
.\scripts\Show-Pairing.ps1
```

This opens the private pairing QR for the iOS app to scan. To open it manually, use `%LOCALAPPDATA%\PCControl\pairing.html`. Keep the QR private because it grants access to the paired PC.

The workflow is manual-dispatch only. To create a later TestFlight build, run **Build iOS and upload to TestFlight** from the repository's GitHub Actions page. It archives and signs on GitHub's macOS runner and does not run tests.
