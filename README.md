# PC Control

A small, invisible Windows agent for a future local iOS remote. Written in Go, compiled to a standalone GUI-subsystem executable: no console, tray icon, browser, .NET runtime, cloud service, or account. Installed on this PC in `%LOCALAPPDATA%\PCControl`.

Controls master volume/mute, each compatible display's hardware brightness, relative/absolute mouse movement, buttons/dragging, smooth wheel scrolling, Unicode text, keyboard shortcuts, media keys, lock, and cancellable shutdown. HTTPS handles individual commands; one persistent authenticated WebSocket handles responsive touchpad/keyboard input. See **[INTEGRATION.md](INTEGRATION.md)** for the complete next-agent handoff.

## Installed service

- LAN address on this installation: `https://192.168.4.62:48180` / `wss://192.168.4.62:48180/v1/ws`. DHCP can change the IP; use Bonjour `_pccontrol._tcp` discovery.
- Task Scheduler task: **PC Control**, starts at Windows sign-in, runs with the user's ordinary permissions and no time limit. It requires a signed-in desktop session. It does not unlock Windows or control the secure desktop.
- A supervisor restarts a failed worker with a 1–30 second backoff. A native control call stalled for eight seconds exits the worker for recovery. A Windows job ties the worker to the supervisor. Task Scheduler's failure restart and an independent one-minute recurring trigger recover a stopped supervisor. Repeated triggers are ignored while the task is already running.
- At idle there is no screenshot capture, hardware polling, keyboard hook, or desktop scan. Only the listening socket and Bonjour announcement remain active. Idle resource measurements are in [VERIFICATION.md](VERIFICATION.md).
- Private `connection.json` contains the bearer token and TLS certificate fingerprint. The installation directory allows only the current user, SYSTEM, and administrators. Do not commit or log the file or token.
- Windows Firewall allows this executable's TCP 48180 and Bonjour UDP 5353 from `LocalSubnet` only, including the PC's current Public network profile. No router forwarding or remote server is required.
- Logs are bounded to a current 1 MiB file and one rotated copy for each process. No text, input commands, passwords, or bearer tokens are logged.

## Build / install / update

Use Windows x64, PowerShell 7 for verification scripts, and Go 1.26.11 or newer (the module requests the patched toolchain automatically). From this folder in PowerShell:

```powershell
go test ./...
go vet ./...
.\scripts\Install.ps1
```

The installer builds the executable, preserves existing pairing/certificate files, updates the scheduled task, starts the agent, and requests Windows elevation once for scoped firewall rules. Later updates can use `-SkipFirewall` if the existing rules and port are unchanged. Updating briefly disconnects controllers; keys/buttons held by the remote are released during restart recovery.

```powershell
.\scripts\Status.ps1
# Tests that briefly stop/restart the installed agent:
.\scripts\Test-Installation.ps1 -TestSupervisorRecovery
# Live tests briefly create a dedicated input-test window and change/restore audio/brightness:
$env:PC_CONTROL_LIVE = '1'
go test -v -run '^TestLive' -count=1 .
Remove-Item Env:PC_CONTROL_LIVE
```

Live input tests restore cursor position and previous foreground window. They capture media keys in the test window, avoiding playback changes in another application. Shutdown tests schedule and cancel a timer; they do not power off the PC.

## Stop / remove

```powershell
.\scripts\Uninstall.ps1
# Also revoke pairing/delete the certificate:
.\scripts\Uninstall.ps1 -RemovePairing
```

Uninstall removes startup and the executable, preserving credentials by default. Run it elevated to also remove the two named firewall rules. Logs remain available for diagnosis. Do not just kill the worker to stop the service: it is deliberately restarted.

## Boundaries

Mouse and keyboard input target the active Windows desktop and focused application. Windows blocks ordinary applications from injecting into elevated applications, UAC prompts, and the lock screen. Display brightness requires hardware DDC/CI for external monitors (sometimes enabled in the monitor's on-screen menu) or WMI brightness support for built-in panels. Both current external displays were tested; the WMI fallback cannot be live-tested on this desktop. Media-key behavior follows the application that handles Windows media keys. This agent supplies controls, not screen mirroring or an iOS user interface.

Native API references: [SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput), [Core Audio](https://learn.microsoft.com/en-us/windows/win32/api/endpointvolume/nn-endpointvolume-iaudioendpointvolume), [monitor configuration](https://learn.microsoft.com/en-us/windows/win32/monitor/monitor-configuration-functions), [WMI brightness](https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmisetbrightness-method-in-class-wmimonitorbrightnessmethods), [Windows service desktop isolation](https://learn.microsoft.com/en-us/windows/desktop/services/interactive-services).
