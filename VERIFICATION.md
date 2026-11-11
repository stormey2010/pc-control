# Verification — November 10, 2026

PC: Windows 11 Home x64, hostname `PC`, LAN `192.168.4.62`. Installed agent version 1.0.0, built with **Go 1.26.11**. Final task/process/health checks confirmed the installed worker and supervisor running.

## Results

| Check | Result |
| --- | --- |
| `go test -v ./...` | Passed; opt-in hardware tests skipped here and run separately below |
| `go vet ./...` | Passed |
| `govulncheck` | **No vulnerabilities found** after updating the build toolchain |
| Live installed-agent tests | All three passed: audio/displays, shutdown cancellation, WebSocket/native input |
| Native watchdog | A deliberately stalled child test exited for recovery after about eight seconds; cancellation also tested |
| PowerShell scripts | All parsed without errors; installation/update/status/crash checks executed |
| Executable integrity | Installed executable SHA-256 matched the published `dist` executable |
| Credential storage | Directory ACL readback: current user, SYSTEM, Administrators only; inheritance disabled |
| Firewall | Both executable-scoped rules enabled; `LocalSubnet` only, TCP 48180 and UDP 5353 |
| Independent LAN client | TLS leaf pin, `/health`, unauthenticated 401 boundary, and Bonjour response verified from `192.168.4.65` |

## Hardware and input

- Default playback volume changed by one percentage point, read back, and restored to **34%**. Mute toggled, read back, and restored to **unmuted**.
- Both current external 1920×1080 displays exposed DDC/CI brightness. Each was changed from **100% to 99%**, independently read back, and restored to **100%**. No display gamma or software dimming was used.
- An isolated temporary Win32 test window received Unicode text containing accented Latin, Japanese, and emoji, Enter, a real pointer click, wheel scrolling, and a Windows media key. Cursor position and previous foreground window were restored afterward.
- Absolute cursor placement was checked against `GetCursorPos`. This caught and resolved a one-pixel normalization issue during development.
- Explicit input release, keep-alive renewal, automatic held-key expiry, and release after WebSocket disconnect passed.
- 200 actual WebSocket mouse-command round trips on **localhost**: **0.069 ms median**, **0.152 ms p95** in the final hardware run. These are PC-side transport/application measurements; they exclude Wi-Fi, phone gestures, iOS scheduling, and display refresh. Input acknowledgements arrived before a concurrent monitor-enumeration reply, confirming the independent fast path.
- Shutdown was scheduled with a 300-second delay, observed pending, immediately cancelled, and observed no longer pending. **The PC was not shut down or locked.**

## Recovery and idle use

- Forced worker termination: final run recovered in **1.11 seconds**, with a new PID and healthy API.
- Forced supervisor termination: its Windows job also removed the worker; the independent Task Scheduler watchdog recovered the full tree in **58.74 seconds** in the supervisor test.
- The scheduled task has interactive logon startup, unlimited execution time, battery-friendly settings, one-minute recurring recovery, and duplicate-instance suppression. A periodic watchdog launch can be declined while the original task is already running; use task/process state and `/health` to assess service health rather than that duplicate-launch result alone.
- Final idle sample for worker + supervisor: **15.62 CPU milliseconds over 15.1 seconds** (about 0.1% of one core averaged over that sample), **21.8 MiB combined working set**. An earlier 15-second sample recorded zero CPU milliseconds. Idle usage is a short measurement, not a guarantee of identical future scheduling.
- A final stress/check run encountered transient stalls in native calls. An eight-second native-call watchdog was added; the complete live suite then passed again. The watchdog exits a stalled worker so supervision can restore usable control instead of retaining a blocked native lock.

## Scope of proof

Startup configuration and restart behavior were verified without rebooting or logging out of the user's PC. Built-in-panel WMI brightness could not be exercised because this desktop uses external displays. Media-key delivery was captured in the test fixture; behavior in a specific media app depends on that app. No physical iPhone client has been built or tested. Windows secure-desktop/elevated-window input restrictions still apply.

Full local outputs are in ignored `artifacts/unit-tests.txt`, `artifacts/live-tests.txt`, `artifacts/installation-tests.txt`, and `artifacts/govulncheck.txt`. Runtime logs are in `%LOCALAPPDATA%\PCControl`. Credentials are intentionally omitted from this report and the repository.

Final installed executable SHA-256:

```text
7E642D57AA34754CFB313B647AD82270C3D8D2B2C2EC41B1AFBFB7CADBDF5CEB
```
