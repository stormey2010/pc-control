# PC Control for iPhone and iPad

Native SwiftUI/UIKit client for the local Windows PC Control agent. iOS 17+. No cloud relay, account, tracking SDK, or bundled pairing credentials.

The main screen has a large frame-coalesced trackpad, left/right click buttons, keyboard access, media keys, and master volume. Two fingers scroll, two-finger tap right-clicks, and a brief stationary hold starts dragging. Displays has independent hardware brightness sliders. Settings has pointer sensitivity, natural scrolling, haptics, paired-PC identity, and confirmed lock/shutdown controls.

## Install with TestFlight

App Store Connect app: **Pc remote console**, ID **6833300906**, bundle **app.pccontrol.remote**.

The GitHub Actions workflow **Build iOS and upload to TestFlight** runs on a macOS runner, generates the Xcode project with XcodeGen, archives/signs the Release app, and uploads through Apple's API credentials in the encrypted `PC_CONTROL_SIGNING_BUNDLE` repository secret. It runs **no tests**. After Apple processes a build, add it to an internal TestFlight testing group and install using the TestFlight app.

For another build:

```powershell
gh workflow run ios-testflight.yml --repo stormey2010/pc-control
```

## Pair with this PC

1. Connect the iPhone and PC to the same local network; Windows must be signed in.
2. On the PC run `scripts/Show-Pairing.ps1` to display the private pairing code.
3. In the iPhone app tap **Scan PC setup code**. Camera access is only needed for this step.
4. Alternatively transfer the PC's private `%LOCALAPPDATA%\PCControl\connection.json` file to the phone and use **Import setup file**. Treat the file like a password and keep it out of public repositories and messages.

The app stores the token and certificate pin in iOS Keychain. Bonjour follows local IP changes. The pinned leaf certificate must match the pairing; changed certificates are rejected. A continuous receive loop drains acknowledgements. Adjacent movement frames are coalesced in a bounded ordered queue, never across clicks/keystrokes. Display writes allow one outstanding request per display and retain only the latest unsent slider value. Audio writes use the same latest-value approach. Disconnection drops stale input. Held input gets a 500 ms keep-alive only while dragging and is explicitly released when leaving the app.

Camera capture starts only on the scan screen. Hardware state is refreshed on connection or manual refresh. Backgrounding stops discovery, timers, and the socket. Mouse/keyboard controls cannot unlock Windows, bypass UAC, or interact with elevated windows. Media keys are delivered to Windows; the media application decides how to respond.

## Mac development

Install Xcode and XcodeGen, then:

```sh
xcodegen generate --spec ios/PCControl/project.yml
open ios/PCControl/PCControl.xcodeproj
```

Choose the **PCControl** scheme and your device. Signing uses Apple team `JUV7448PYM`. Source generation is deterministic; generated `.xcodeproj` files are ignored. Native package `RemoteCore` contains protocol, validated pairing import, motion accumulation, input buffering, and Unicode edit calculation.

The initial release is compiled and signed remotely without tests at the user's request. A successful archive/upload does not establish physical-device interaction quality. See `RELEASE.md` for the exact shipped build status.
