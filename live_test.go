package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"sync"
	"testing"
	"time"
	"unicode/utf16"
	"unsafe"

	"github.com/gorilla/websocket"
	"golang.org/x/sys/windows"
)

func liveConnection(t *testing.T) (Connection, *tls.Config) {
	t.Helper()
	if os.Getenv("PC_CONTROL_LIVE") != "1" {
		t.Skip("Set PC_CONTROL_LIVE=1 for reversible hardware checks against the installed agent")
	}
	var c Connection
	b, e := os.ReadFile(filepath.Join(os.Getenv("LOCALAPPDATA"), "PCControl", "connection.json"))
	if e != nil {
		t.Fatal(e)
	}
	if e = json.Unmarshal(b, &c); e != nil {
		t.Fatal(e)
	}
	cfg := &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true, VerifyConnection: func(s tls.ConnectionState) error {
		if len(s.PeerCertificates) == 0 {
			return fmt.Errorf("missing certificate")
		}
		sum := sha256.Sum256(s.PeerCertificates[0].Raw)
		if hex.EncodeToString(sum[:]) != c.CertificateSHA256 {
			return fmt.Errorf("certificate pin mismatch")
		}
		if time.Now().After(s.PeerCertificates[0].NotAfter) {
			return fmt.Errorf("expired certificate")
		}
		return nil
	}}
	return c, cfg
}
func liveCall(t *testing.T, c Connection, cfg *tls.Config, cmd Command) Reply {
	t.Helper()
	b, _ := json.Marshal(cmd)
	req, e := http.NewRequest("POST", fmt.Sprintf("https://127.0.0.1:%d/v1/command", c.Port), bytes.NewReader(b))
	if e != nil {
		t.Fatal(e)
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("Content-Type", "application/json")
	tr := &http.Transport{TLSClientConfig: cfg}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 15 * time.Second}
	res, e := client.Do(req)
	if e != nil {
		t.Fatal(e)
	}
	defer res.Body.Close()
	var r Reply
	if e = json.NewDecoder(res.Body).Decode(&r); e != nil {
		t.Fatal(e)
	}
	if !r.OK {
		t.Fatalf("%s failed: %v", cmd.Op, r.Error)
	}
	return r
}
func TestLiveAudioAndDisplays(t *testing.T) {
	c, cfg := liveConnection(t)
	r := liveCall(t, c, cfg, Command{Op: "audio.get"})
	b, _ := json.Marshal(r.Result)
	var audio AudioState
	json.Unmarshal(b, &audio)
	defer liveCall(t, c, cfg, Command{Op: "audio.set", Level: &audio.Level, Muted: &audio.Muted})
	level := audio.Level + 1
	if level > 100 {
		level = audio.Level - 1
	}
	r = liveCall(t, c, cfg, Command{Op: "audio.set", Level: &level})
	b, _ = json.Marshal(r.Result)
	var changed AudioState
	json.Unmarshal(b, &changed)
	if absFloat(changed.Level-level) > 0.05 {
		t.Fatal("audio set/read mismatch")
	}
	liveCall(t, c, cfg, Command{Op: "audio.set", Level: &audio.Level, Muted: &audio.Muted})
	toggle := !audio.Muted
	r = liveCall(t, c, cfg, Command{Op: "audio.set", Muted: &toggle})
	b, _ = json.Marshal(r.Result)
	json.Unmarshal(b, &changed)
	if changed.Muted != toggle {
		t.Fatal("mute set/read mismatch")
	}
	liveCall(t, c, cfg, Command{Op: "audio.set", Muted: &audio.Muted})
	t.Logf("Volume set/read/restore verified (original %.2f%%)", audio.Level)
	r = liveCall(t, c, cfg, Command{Op: "displays.list"})
	b, _ = json.Marshal(r.Result)
	var displays []Display
	json.Unmarshal(b, &displays)
	if len(displays) == 0 {
		t.Fatal("No displays discovered")
	}
	for _, d := range displays {
		d := d
		if !d.Supported || d.Brightness == nil {
			t.Logf("Unsupported display: %s (%s)", d.ID, d.Reason)
			continue
		}
		old := *d.Brightness
		defer liveCall(t, c, cfg, Command{Op: "display.set", Display: d.ID, Level: &old})
		changed := old - 1
		if changed < 0 {
			changed = old + 1
		}
		liveCall(t, c, cfg, Command{Op: "display.set", Display: d.ID, Level: &changed})
		r = liveCall(t, c, cfg, Command{Op: "displays.list"})
		b, _ = json.Marshal(r.Result)
		var current []Display
		json.Unmarshal(b, &current)
		verified := false
		for _, v := range current {
			if v.ID == d.ID && v.Brightness != nil && absFloat(*v.Brightness-changed) < 1.1 {
				verified = true
			}
		}
		if !verified {
			t.Fatalf("Brightness readback failed for %s", d.ID)
		}
		liveCall(t, c, cfg, Command{Op: "display.set", Display: d.ID, Level: &old})
		t.Logf("Brightness set/read/restore verified: %s (%.0f%%)", d.ID, old)
	}
}
func absFloat(v float64) float64 {
	if v < 0 {
		return -v
	}
	return v
}

func TestLiveShutdownCancellation(t *testing.T) {
	c, cfg := liveConnection(t)
	status := liveCall(t, c, cfg, Command{Op: "system.status"})
	if status.Result.(map[string]any)["shutdownPending"] == true {
		t.Skip("Existing user shutdown preserved")
	}
	delay := 300
	defer liveCall(t, c, cfg, Command{Op: "system.cancelShutdown"})
	liveCall(t, c, cfg, Command{Op: "system.shutdown", Confirm: "shutdown", Delay: &delay})
	status = liveCall(t, c, cfg, Command{Op: "system.status"})
	if status.Result.(map[string]any)["shutdownPending"] != true {
		t.Fatal("Shutdown not pending")
	}
	r := liveCall(t, c, cfg, Command{Op: "system.cancelShutdown"})
	if r.Result.(map[string]any)["cancelled"] != true {
		t.Fatal("Shutdown not cancelled")
	}
	status = liveCall(t, c, cfg, Command{Op: "system.status"})
	if status.Result.(map[string]any)["shutdownPending"] != false {
		t.Fatal("Cancelled shutdown retained")
	}
	t.Log("Installed API shutdown schedule/status/cancel verified; no power-off performed")
}

type fixtureEvents struct {
	sync.Mutex
	chars  []uint16
	clicks int
	wheels int
	media  int
	enters int
}

var fixture fixtureEvents
var fixtureProc = windows.NewCallback(func(hwnd uintptr, msg uint32, w, l uintptr) uintptr {
	fixture.Lock()
	switch msg {
	case 0x102:
		fixture.chars = append(fixture.chars, uint16(w))
	case 0x201:
		fixture.clicks++
	case 0x20A:
		fixture.wheels++
	case 0x100:
		if w == 13 {
			fixture.enters++
		}
		if w == 0xB3 {
			fixture.media++
		}
	case 0x319:
		fixture.media++
		fixture.Unlock()
		return 1
	}
	fixture.Unlock()
	r, _, _ := user32.NewProc("DefWindowProcW").Call(hwnd, uintptr(msg), w, l)
	return r
})

type wndClass struct {
	Size, Style                        uint32
	Proc                               uintptr
	ClassExtra, WndExtra               int32
	Instance, Icon, Cursor, Background uintptr
	MenuName, ClassName                *uint16
	SmallIcon                          uintptr
}
type message struct {
	Window  uintptr
	ID      uint32
	W, L    uintptr
	Time    uint32
	X, Y    int32
	Private uint32
}
type point struct{ X, Y int32 }

func pump() {
	deadline := time.Now().Add(80 * time.Millisecond)
	for time.Now().Before(deadline) {
		var m message
		for {
			r, _, _ := user32.NewProc("PeekMessageW").Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0, 1)
			if r == 0 {
				break
			}
			user32.NewProc("TranslateMessage").Call(uintptr(unsafe.Pointer(&m)))
			user32.NewProc("DispatchMessageW").Call(uintptr(unsafe.Pointer(&m)))
		}
		time.Sleep(time.Millisecond)
	}
}
func TestLiveWebSocketInputAndLatency(t *testing.T) {
	c, cfg := liveConnection(t)
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	fixture.Lock()
	fixture.chars = nil
	fixture.clicks = 0
	fixture.wheels = 0
	fixture.media = 0
	fixture.enters = 0
	fixture.Unlock()
	oldWindow, _, _ := user32.NewProc("GetForegroundWindow").Call()
	var oldPoint point
	user32.NewProc("GetCursorPos").Call(uintptr(unsafe.Pointer(&oldPoint)))
	defer func() {
		user32.NewProc("SetCursorPos").Call(uintptr(oldPoint.X), uintptr(oldPoint.Y))
		user32.NewProc("SetForegroundWindow").Call(oldWindow)
	}()
	name, _ := windows.UTF16PtrFromString("PCControlVerification")
	var instance windows.Handle
	if e := windows.GetModuleHandleEx(2, nil, &instance); e != nil {
		t.Fatal(e)
	}
	wc := wndClass{Proc: fixtureProc, ClassName: name, Instance: uintptr(instance)}
	wc.Size = uint32(unsafe.Sizeof(wc))
	atom, _, e := user32.NewProc("RegisterClassExW").Call(uintptr(unsafe.Pointer(&wc)))
	if atom == 0 {
		t.Fatal(e)
	}
	defer user32.NewProc("UnregisterClassW").Call(uintptr(unsafe.Pointer(name)), uintptr(instance))
	title, _ := windows.UTF16PtrFromString("PC Control verification")
	hwnd, _, e := user32.NewProc("CreateWindowExW").Call(0, uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(title)), 0x10CF0000, 200, 200, 420, 200, 0, 0, uintptr(instance), 0)
	if hwnd == 0 {
		t.Fatal(e)
	}
	defer user32.NewProc("DestroyWindow").Call(hwnd)
	user32.NewProc("SetForegroundWindow").Call(hwnd)
	user32.NewProc("SetFocus").Call(hwnd)
	pump()
	active, _, _ := user32.NewProc("GetForegroundWindow").Call()
	if active != hwnd {
		t.Fatal("Could not focus isolated input test window")
	}
	dial := websocket.Dialer{TLSClientConfig: cfg, HandshakeTimeout: 5 * time.Second}
	ws, _, e := dial.Dial(fmt.Sprintf("wss://127.0.0.1:%d/v1/ws", c.Port), http.Header{"Authorization": []string{"Bearer " + c.Token}})
	if e != nil {
		t.Fatal(e)
	}
	defer ws.Close()
	ws.SetReadDeadline(time.Now().Add(20 * time.Second))
	var ready any
	if e = ws.ReadJSON(&ready); e != nil {
		t.Fatal(e)
	}
	id := 0
	call := func(cmd Command) {
		t.Helper()
		id++
		cmd.ID = mustJSON(id)
		if e = ws.WriteJSON(cmd); e != nil {
			t.Fatal(e)
		}
		var r Reply
		if e = ws.ReadJSON(&r); e != nil || !r.OK {
			t.Fatalf("%s: %v %v", cmd.Op, e, r.Error)
		}
	}
	text := "PC Control: café 日本語 🚀"
	call(Command{Op: "keyboard.text", Text: text})
	pump()
	call(Command{Op: "keyboard.key", Key: "enter"})
	pump()
	x, y := int32(300), int32(300)
	call(Command{Op: "mouse.move", X: &x, Y: &y})
	pump()
	var p point
	user32.NewProc("GetCursorPos").Call(uintptr(unsafe.Pointer(&p)))
	if p.X != x || p.Y != y {
		t.Fatalf("absolute cursor position mismatch: %v", p)
	}
	call(Command{Op: "mouse.button", Button: "left", Action: "click"})
	pump()
	dy := int32(120)
	call(Command{Op: "mouse.scroll", DY: &dy})
	pump()
	call(Command{Op: "media.key", Key: "playPause"})
	pump()
	fixture.Lock()
	got := string(utf16.Decode(fixture.chars))
	clicks, wheels, media, enters := fixture.clicks, fixture.wheels, fixture.media, fixture.enters
	fixture.Unlock()
	if got != text+"\r" {
		t.Fatalf("Unicode input mismatch: %q", got)
	}
	if clicks < 1 || wheels < 1 || media < 1 || enters < 1 {
		t.Fatalf("input events missing: clicks=%d wheel=%d media=%d enter=%d", clicks, wheels, media, enters)
	}
	// Explicit release and lease renewal/expiry protect against interrupted gestures.
	call(Command{Op: "mouse.button", Button: "left", Action: "down"})
	pump()
	call(Command{Op: "input.release"})
	pump()
	buttonState, _, _ := user32.NewProc("GetAsyncKeyState").Call(1)
	if buttonState&0x8000 != 0 {
		t.Fatal("input.release left mouse button held")
	}
	call(Command{Op: "keyboard.key", Key: "shift", Action: "down"})
	pump()
	for i := 0; i < 5; i++ {
		time.Sleep(450 * time.Millisecond)
		call(Command{Op: "input.keepAlive"})
		pump()
	}
	heldState, _, _ := user32.NewProc("GetAsyncKeyState").Call(0x10)
	if heldState&0x8000 == 0 {
		t.Fatal("keepAlive did not renew held-input lease")
	}
	time.Sleep(2700 * time.Millisecond)
	pump()
	heldState, _, _ = user32.NewProc("GetAsyncKeyState").Call(0x10)
	if heldState&0x8000 != 0 {
		t.Fatal("expired input lease did not release modifier")
	}
	call(Command{Op: "keyboard.key", Key: "shift", Action: "down"})
	pump()
	state, _, _ := user32.NewProc("GetAsyncKeyState").Call(0x10)
	if state&0x8000 == 0 {
		t.Fatal("held modifier was not delivered")
	}
	ws.Close()
	pump()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		state, _, _ = user32.NewProc("GetAsyncKeyState").Call(0x10)
		if state&0x8000 == 0 {
			break
		}
		pump()
	}
	if state&0x8000 != 0 {
		t.Fatal("disconnect did not release held modifier")
	}
	ws, _, e = dial.Dial(fmt.Sprintf("wss://127.0.0.1:%d/v1/ws", c.Port), http.Header{"Authorization": []string{"Bearer " + c.Token}})
	if e != nil {
		t.Fatal(e)
	}
	defer ws.Close()
	ws.ReadJSON(&ready)
	zero := int32(0)
	latencies := make([]float64, 200)
	qpc := windows.NewLazySystemDLL("kernel32.dll").NewProc("QueryPerformanceCounter")
	var frequency int64
	windows.NewLazySystemDLL("kernel32.dll").NewProc("QueryPerformanceFrequency").Call(uintptr(unsafe.Pointer(&frequency)))
	for i := range latencies {
		var begin, end int64
		qpc.Call(uintptr(unsafe.Pointer(&begin)))
		call(Command{Op: "mouse.move", DX: &zero, DY: &zero})
		qpc.Call(uintptr(unsafe.Pointer(&end)))
		latencies[i] = float64(end-begin) * 1000 / float64(frequency)
	}
	sort.Float64s(latencies)
	t.Logf("Real Unicode typing, Enter, pointer position, click, scroll, media and disconnect release verified; 200 mouse-command round trips: median %.3f ms, p95 %.3f ms", latencies[100], latencies[190])
	// A slow hardware read must not delay a later input command on the same connection.
	ws.WriteJSON(Command{ID: mustJSON("display"), Op: "displays.list"})
	start := time.Now()
	ws.WriteJSON(Command{ID: mustJSON("fast"), Op: "mouse.move", DX: &zero, DY: &zero})
	var first Reply
	if e = ws.ReadJSON(&first); e != nil {
		t.Fatal(e)
	}
	elapsed := time.Since(start)
	if string(first.ID) != `"fast"` {
		t.Fatal("display read blocked input lane")
	}
	if elapsed > 100*time.Millisecond {
		t.Fatalf("input stalled during display read: %s", elapsed)
	}
	ws.ReadJSON(&first)
	t.Logf("Input remained responsive during display hardware read: %s", elapsed)
}
