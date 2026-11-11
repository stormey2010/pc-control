# Next-agent handoff: Windows PC Control → iOS

The PC side is implemented and installed. Build the iOS client against this protocol; do not replace the background agent or put an HTTP server in the app. Protocol version: **1**, service version: **1.0.0**.

## Find and pair

1. Discover Bonjour service `_pccontrol._tcp` in `local.` using `NWBrowser` or `NetServiceBrowser`. Resolve the announced host and port. TXT records: `version=1`, `id=<stable device ID>`, `tls=1`, `path=/v1/ws`. Discovery is public metadata, not authorization. Identify a paired PC by device ID and certificate pin, not its name or IP.
2. For initial development, this PC is at **192.168.4.62:48180**. The private provisioning file is **`C:\Users\parke\AppData\Local\PCControl\connection.json`**. Read it locally; never paste its token into source, logs, a commit, or an agent conversation. Fields: `version`, `deviceId`, `name`, `port`, `urls`, `token`, `certificateSha256`, `discovery`. Ignore WSL/virtual-interface addresses if manually choosing a LAN URL. Connection URLs are a startup snapshot; Bonjour follows address changes.
3. Provision the token and certificate SHA-256 fingerprint to the phone out of band (for example, an explicit local QR/import flow implemented by the app developer). There is deliberately no unauthenticated network pairing endpoint. Store the token in iOS Keychain and the fingerprint with the paired device. A copied token grants control of this desktop.
4. Use TLS and pin the exact server leaf certificate's DER bytes: SHA-256, lowercase hexadecimal, no separators. The certificate is self-signed and stable across restarts/updates. In the `URLSessionDelegate` server-trust challenge, accept only the previously paired certificate fingerprint (also check certificate validity); reject all other certificates. Do not use a global trust-all handler. A DHCP address change need not change the certificate or pairing.
5. Include `Authorization: Bearer <token>` in the HTTPS request or WebSocket upgrade. Query-string tokens and cookies are not supported. Native requests should omit `Origin`; browser origins are rejected.

iOS `Info.plist` needs `NSLocalNetworkUsageDescription` and `NSBonjourServices` containing `_pccontrol._tcp`. Request LAN permission from a clear connection flow. Use HTTPS/WSS; no broad arbitrary-load ATS exception is needed. Connect while the app is foregrounded and close the controller when backgrounding.

## Endpoints

| Endpoint | Authentication | Result |
| --- | --- | --- |
| `GET /health` | None | Minimal liveness/version; no device credentials or controls |
| `GET /v1/info` | Bearer | Device/protocol identity, uptime, physical virtual-desktop bounds, capabilities |
| `POST /v1/command` | Bearer | One JSON command and one JSON reply |
| `GET /v1/ws` | Bearer on upgrade | Persistent WebSocket carrying the same JSON commands/replies |

`POST` content type: `application/json`. Messages must be single JSON objects with known fields only, up to **16,384 bytes**. `keyboard.text` allows **2,048 UTF-16 code units** per command. IDs are optional string/number values up to 128 encoded bytes; use a unique increasing ID per connection. Reply IDs correlate asynchronous operations; replies across control lanes may arrive out of order.

```json
{"id":42,"op":"audio.set","level":35,"muted":false}
```

```json
{"id":42,"ok":true,"result":{"level":35,"muted":false}}
```

```json
{"id":43,"ok":false,"error":{"code":"unsupported","message":"..."}}
```

HTTP status is 200 on successful commands, 400 on command/action failure, 401 for invalid pairing, 403 for disallowed network/origin, 409 for an occupied WebSocket, 413 for an oversized HTTP body, and 429 when a request/authentication limit is reached. Always inspect `ok` and `error.code`. Codes include `invalid_command`, `action_failed`, `unauthorized`, `unsupported`, `display_unavailable`, `input_busy`, `busy`, `already_pending`. Repeated invalid credentials are throttled for up to one minute. Network/TLS failures must be surfaced separately from command errors.

## WebSocket flow and responsiveness

Open **`wss://192.168.4.62:48180/v1/ws`** using `URLSessionWebSocketTask` with the bearer header and pinned session delegate. On upgrade the agent sends:

```json
{"event":"ready","info":{"version":"1.0.0","protocolVersion":1,"deviceId":"...","name":"PC","desktop":{"x":0,"y":0,"width":3840,"height":1080},"maxMessageBytes":16384,"maxWebSockets":1}}
```

Only **one controller WebSocket** is allowed at once. While connected, send all mouse/keyboard/media/input operations through it; REST input returns `input_busy`. REST audio/display/system commands remain available. Audio, display, and other slow commands have independent bounded queues, while mouse/keyboard input is applied directly. A monitor hardware request cannot block touchpad events.

- Send relative movement at 60–120 Hz. Coalesce unsent movement deltas to the latest frame; never build an unbounded UI queue and never wait for every acknowledgement before sending the next frame. Keep the receive loop running to consume replies. Reconnect if the client cannot keep up.
- Use optimistic slider updates. Coalesce audio changes to roughly 20 Hz. For hardware brightness, allow one outstanding request per display, replacing an unsent value with the latest slider value; send the final value on gesture end. DDC/CI takes tens to hundreds of milliseconds depending on the monitor, and is not a 120 Hz channel. Refresh hardware state on connection or explicit refresh, not continuously while idle.
- Send JSON `{"op":"ping","id":...}` every **15 seconds** while connected, or use WebSocket protocol pings. The idle read timeout is **45 seconds**. Close cleanly on app background/disconnect. A slow receiver is disconnected after bounded output buffering or a 3-second write timeout.
- A held mouse button or key has a **2-second lease**, checked every 500 ms. Motion/keyboard/media/input commands renew it. During a stationary drag or long key hold, send `input.keepAlive` every **500 ms**. Ordinary `ping` preserves the connection but does not renew held input. `input.release` immediately releases all remotely held inputs.
- On disconnect, expired lease, failed injection, or worker restart, remotely held keys/buttons are released. Only held key/button IDs are persisted privately for crash cleanup; typed text and pointer movements are never recorded. The iOS app should still send explicit button/key up on gesture end/cancel and `input.release` before backgrounding.
- Retry connection with jittered backoff (for example 0.5, 1, 2, 4 seconds, capped at 10). After reconnect, read `info`, `audio.get`, and `displays.list`. Reconcile state and clear gesture state. Do not replay stale input, clicks, shortcuts, media toggles, or shutdown commands: there is no deduplication/exactly-once guarantee. Volume/brightness absolute setters are safe to resend intentionally.
- A native control call stalled for eight seconds terminates the worker and drops connections. The supervisor restarts it automatically. Treat this as a recoverable transport failure. `GET /v1/diagnostics` is an authenticated **loopback-only** support endpoint for Go goroutine stacks; it is unavailable to LAN/iOS clients.

## Commands

| `op` | Fields | Behavior |
| --- | --- | --- |
| `ping` | — | Returns server UTC time |
| `info` | — | Same metadata as `/v1/info` |
| `audio.get` | — | Default multimedia playback endpoint's level 0–100 and muted state |
| `audio.set` | `level`: 0–100 and/or `muted`: boolean | Absolute volume/mute; returns actual readback; follows default audio device changes |
| `displays.list` | — | Array of display IDs, names, backend, bounds where available, brightness 0–100, `supported` and optional reason |
| `display.set` | `display`: returned ID, `level`: 0–100 | Hardware brightness; returns quantized requested level after successful hardware write; use `displays.list` for independent readback |
| `mouse.move` | `dx` AND `dy`: signed integers | Relative trackpad movement; Windows pointer acceleration applies; each delta must be within ±10,000 |
| `mouse.move` | `x` AND `y`: signed integers | Absolute **physical pixel** position on the virtual desktop; negative coordinates are valid if within bounds; cannot mix with deltas |
| `mouse.button` | `button`: `left`/`right`/`middle`, `action`: `click`/`down`/`up` | Click, hold/drag, release; `down`/`up` require WebSocket |
| `mouse.scroll` | `dx` and/or `dy`: signed integers | Windows wheel units; **120 = one detent**, smaller units allow smooth scrolling; positive dy scrolls up, positive dx scrolls right; ±12,000 per axis |
| `keyboard.text` | `text`: Unicode string | Types into the currently focused Windows input using Unicode injection, including emoji; does not alter the clipboard |
| `keyboard.key` | `key`, optional `action`: `press`/`down`/`up`, optional `modifiers` | Physical-style keys/shortcuts. Modifiers require `press`; held keys require WebSocket |
| `media.key` | `key`: `playPause`/`next`/`previous`/`stop`/`volumeUp`/`volumeDown`/`volumeMute` | Windows media key event; the active/media application determines behavior |
| `input.keepAlive` | — | Renew the held-input lease without moving the cursor |
| `input.release` | — | Release all keys/buttons held by this controller |
| `system.shutdown` | `confirm`: **`shutdown`**, optional `delaySeconds`: 5–300 | Schedule shutdown; default 30 seconds; acknowledgement means scheduled, not powered off |
| `system.cancelShutdown` | — | Cancel the agent's pending timer; returns `cancelled` |
| `system.status` | — | Pending shutdown state and timestamp |
| `system.lock` | — | Lock the Windows desktop |

Keys are case-insensitive: A–Z, 0–9, F1–F24, `backspace`, `tab`, `enter`, `shift`, `ctrl`, `alt`, `escape`, `space`, `pageUp`, `pageDown`, `end`, `home`, `left`, `up`, `right`, `down`, `insert`, `delete`, `meta` (Windows key), and the media key names. Modifiers: unique `ctrl`, `alt`, `shift`, `meta`. Use `keyboard.text` for punctuation, symbols, and composed text. Input is global to the focused application; the agent does not detect which field the user intended.

The shutdown timer is owned by the agent and clears on restart. At expiry it runs `shutdown.exe /s /t 0` without `/f`; applications can block shutdown to protect unsaved work. Show a clear app confirmation and a cancel countdown. An already-executing OS shutdown is not cancellable through this timer endpoint. No shutdown or lock was performed during verification.

## Example messages

```json
{"id":1,"op":"audio.get"}
{"id":2,"op":"audio.set","level":25,"muted":false}
{"id":3,"op":"displays.list"}
{"id":4,"op":"display.set","display":"\\\\.\\DISPLAY1:0","level":65}
{"id":5,"op":"mouse.move","dx":8,"dy":-3}
{"id":6,"op":"mouse.button","button":"left","action":"down"}
{"id":7,"op":"mouse.move","dx":20,"dy":0}
{"id":8,"op":"input.keepAlive"}
{"id":9,"op":"mouse.button","button":"left","action":"up"}
{"id":10,"op":"mouse.scroll","dy":-30}
{"id":11,"op":"keyboard.text","text":"Hello 👋"}
{"id":12,"op":"keyboard.key","key":"a","modifiers":["ctrl"]}
{"id":13,"op":"keyboard.key","key":"enter"}
{"id":14,"op":"media.key","key":"playPause"}
{"id":15,"op":"input.release"}
{"id":16,"op":"system.shutdown","confirm":"shutdown","delaySeconds":30}
{"id":17,"op":"system.cancelShutdown"}
```

Display IDs should be obtained from `displays.list`, not hardcoded. Re-enumerate after hot-plug/resume or `display_unavailable`. A `ddc-ci` entry can be unsupported while a separate `wmi` entry for an internal panel is supported; present only supported brightness controls. Physical monitor identities can change with Windows display topology. No brightness emulation via gamma overlays is used.

## Minimal native transport shape (illustration, not an iOS app)

```swift
var request = URLRequest(url: URL(string: "wss://192.168.4.62:48180/v1/ws")!)
request.setValue("Bearer \(keychainToken)", forHTTPHeaderField: "Authorization")
// pinnedSession must use the paired DER certificate SHA-256 fingerprint
// in its server-trust challenge handler, not a trust-all delegate.
let socket = pinnedSession.webSocketTask(with: request)
socket.resume()
try await socket.send(.string(#"{"id":1,"op":"mouse.move","dx":6,"dy":-2}"#))
// Keep exactly one receive loop running; correlate reply IDs and handle `ready`.
let message = try await socket.receive()
```

Keep movement handling off the main actor where practical; publish state to SwiftUI on the main actor. Match the phone's gesture lifetime to down/up/release. Test on a physical iPhone over the same Wi-Fi/LAN; the PC-side verification does not constitute iOS end-to-end validation.

## Source map and maintenance

- `main.go`: credentials, persistent TLS identity, Bonjour, bounded logs, worker supervision/job lifetime.
- `api.go`: LAN/authentication boundary, HTTPS commands, WebSocket ownership, lanes, leases, shutdown scheduling.
- `native_windows.go`: native Core Audio COM, SendInput, DDC/CI, WMI fallback, held-input recovery.
- `api_test.go`: protocol, authentication, bounds, certificates, cancellation, connection lifecycle, native ABI.
- `live_test.go`: opt-in real installed-agent/hardware verification with TLS pinning and isolated input fixture.
- `scripts/`: build/install, firewall, status, removal, crash recovery/idle checks.

To rotate pairing, stop/uninstall the agent with `-RemovePairing`, then reinstall and explicitly pair the phone again. Do not silently accept a changed TLS certificate. For regular updates use `Install.ps1 -SkipFirewall`, preserving credentials. No server at 192.168.4.65 is part of the runtime architecture; it was used only as an independent LAN test client.


## Nearby pairing

Bonjour `_pccontrol._tcp.local.` now advertises `pin` (the public TLS certificate SHA-256) alongside `id` and `tls=1`. Connect to an advertised local HTTPS endpoint with the advertised pin.

- `POST /v1/pair/start` with `{}` needs no bearer token. It shows a code on the PC and returns `{requestId, deviceId, expiresIn:120}`. Requests are limited to one per 30 seconds.
- `POST /v1/pair/confirm` with `{requestId,code}` returns the private connection JSON after a correct four-digit code. Requests are tied to the requesting IP, expire after two minutes, and allow five guesses. A successful request consumes the code and closes the window.
- Persist the returned token and certificate pin, then use the existing authenticated command/WebSocket API. Rediscover by device ID when the LAN address changes. No further pairing request is needed.

The iOS app stores this identity in Keychain. WebSocket JSON commands should be sent as text frames; binary JSON is also accepted for earlier clients.
