package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"unicode/utf16"
	"unsafe"

	ole "github.com/go-ole/go-ole"
	"github.com/go-ole/go-ole/oleutil"
	"golang.org/x/sys/windows"
)

var user32 = windows.NewLazySystemDLL("user32.dll")
var dxva2 = windows.NewLazySystemDLL("dxva2.dll")
var ole32 = windows.NewLazySystemDLL("ole32.dll")

func hiddenProcess() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
}
func winError(op string, e error) error {
	if e == nil || e == syscall.Errno(0) {
		return fmt.Errorf("%s failed (desktop may be locked or elevated)", op)
	}
	return fmt.Errorf("%s: %w", op, e)
}
func lockDesktop() error {
	r, _, e := user32.NewProc("LockWorkStation").Call()
	if r == 0 {
		return winError("LockWorkStation", e)
	}
	return nil
}

type comObject struct{ vtable *[32]uintptr }

func comCall(p *comObject, index int, args ...uintptr) error {
	fn := p.vtable[index]
	a := append([]uintptr{uintptr(unsafe.Pointer(p))}, args...)
	r, _, _ := syscall.SyscallN(fn, a...)
	if int32(r) < 0 {
		return fmt.Errorf("Windows audio HRESULT 0x%08x", uint32(r))
	}
	return nil
}
func comRelease(p *comObject) {
	if p != nil {
		_ = comCall(p, 2)
	}
}

type AudioState struct {
	Level float64 `json:"level"`
	Muted bool    `json:"muted"`
}

func audioControl(c Command) (any, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if e := ole.CoInitializeEx(0, ole.COINIT_MULTITHREADED); e != nil {
		return nil, e
	}
	defer ole.CoUninitialize()
	cls, _ := windows.GUIDFromString("{BCDE0395-E52F-467C-8E3D-C4579291692E}")
	iid, _ := windows.GUIDFromString("{A95664D2-9614-4F35-A746-DE8DB63617E6}")
	volid, _ := windows.GUIDFromString("{5CDF2C82-841E-4546-9722-0CF74078229A}")
	var enumerator, device, volume *comObject
	r, _, _ := ole32.NewProc("CoCreateInstance").Call(uintptr(unsafe.Pointer(&cls)), 0, 23, uintptr(unsafe.Pointer(&iid)), uintptr(unsafe.Pointer(&enumerator)))
	if int32(r) < 0 {
		return nil, fmt.Errorf("Audio device enumeration failed: 0x%x", uint32(r))
	}
	defer comRelease(enumerator)
	if e := comCall(enumerator, 4, 0, 1, uintptr(unsafe.Pointer(&device))); e != nil {
		return nil, e
	}
	defer comRelease(device)
	if e := comCall(device, 3, uintptr(unsafe.Pointer(&volid)), 23, 0, uintptr(unsafe.Pointer(&volume))); e != nil {
		return nil, e
	}
	defer comRelease(volume)
	if c.Op == "audio.set" {
		if c.Level != nil {
			if e := comCall(volume, 7, uintptr(math.Float32bits(float32(*c.Level/100))), 0); e != nil {
				return nil, e
			}
		}
		if c.Muted != nil {
			v := uintptr(0)
			if *c.Muted {
				v = 1
			}
			if e := comCall(volume, 14, v, 0); e != nil {
				return nil, e
			}
		}
	}
	var level float32
	var muted int32
	if e := comCall(volume, 9, uintptr(unsafe.Pointer(&level))); e != nil {
		return nil, e
	}
	if e := comCall(volume, 15, uintptr(unsafe.Pointer(&muted))); e != nil {
		return nil, e
	}
	return AudioState{math.Round(float64(level)*10000) / 100, muted != 0}, nil
}

// INPUT has a 32-byte, 8-byte-aligned union on Windows x64 (total 40 bytes).
type nativeInput struct {
	Kind uint32
	_    uint32
	Data [32]byte
}
type mouseInput struct {
	DX, DY            int32
	Data, Flags, Time uint32
	Extra             uintptr
}
type keyInput struct {
	VK, Scan    uint16
	Flags, Time uint32
	Extra       uintptr
}

func mouseEvent(x, y int32, data, flags uint32) nativeInput {
	n := nativeInput{}
	*(*mouseInput)(unsafe.Pointer(&n.Data[0])) = mouseInput{DX: x, DY: y, Data: data, Flags: flags}
	return n
}
func keyEvent(vk, scan uint16, flags uint32) nativeInput {
	n := nativeInput{Kind: 1}
	*(*keyInput)(unsafe.Pointer(&n.Data[0])) = keyInput{VK: vk, Scan: scan, Flags: flags}
	return n
}
func sendInputs(inputs []nativeInput) error {
	if len(inputs) == 0 {
		return nil
	}
	r, _, e := user32.NewProc("SendInput").Call(uintptr(len(inputs)), uintptr(unsafe.Pointer(&inputs[0])), unsafe.Sizeof(inputs[0]))
	runtime.KeepAlive(inputs)
	if int(r) != len(inputs) {
		return winError("SendInput", e)
	}
	return nil
}

type heldInput struct {
	keys     map[uint16]bool
	buttons  map[string]bool
	savePath string
}

func newHeldInput() *heldInput {
	return &heldInput{keys: map[uint16]bool{}, buttons: map[string]bool{}}
}

type heldState struct {
	Keys    []uint16 `json:"keys"`
	Buttons []string `json:"buttons"`
}

func (h *heldInput) persist() error {
	if h.savePath == "" {
		return nil
	}
	if len(h.keys) == 0 && len(h.buttons) == 0 {
		e := os.Remove(h.savePath)
		if errors.Is(e, os.ErrNotExist) {
			return nil
		}
		return e
	}
	state := heldState{}
	for k := range h.keys {
		state.Keys = append(state.Keys, k)
	}
	for b := range h.buttons {
		state.Buttons = append(state.Buttons, b)
	}
	data, _ := json.Marshal(state)
	if e := os.WriteFile(h.savePath+".tmp", data, 0600); e != nil {
		return e
	}
	return os.Rename(h.savePath+".tmp", h.savePath)
}
func recoverHeldInput(dir string) {
	path := filepath.Join(dir, "held-input.json")
	b, e := os.ReadFile(path)
	if e != nil {
		return
	}
	var state heldState
	if json.Unmarshal(b, &state) != nil {
		_ = os.Remove(path)
		return
	}
	h := newHeldInput()
	h.savePath = path
	for _, k := range state.Keys {
		h.keys[k] = true
	}
	for _, v := range state.Buttons {
		h.buttons[v] = true
	}
	h.release()
}
func (h *heldInput) release() {
	if len(h.keys) == 0 && len(h.buttons) == 0 {
		return
	}
	var a []nativeInput
	for k := range h.keys {
		a = append(a, keyEvent(k, 0, keyFlags(k)|2))
	}
	for b := range h.buttons {
		_, up, _ := buttonFlags(b)
		a = append(a, mouseEvent(0, 0, 0, up))
	}
	_ = sendInputs(a)
	clear(h.keys)
	clear(h.buttons)
	_ = h.persist()
}
func buttonFlags(b string) (uint32, uint32, error) {
	switch b {
	case "left":
		return 2, 4, nil
	case "right":
		return 8, 16, nil
	case "middle":
		return 32, 64, nil
	}
	return 0, 0, invalid("button must be left, right or middle")
}
func keyFlags(k uint16) uint32 {
	switch k {
	case 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x5B, 0x6F, 0x90, 0xA3, 0xA5, 0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3:
		return 1
	}
	return 0
}
func virtualKey(s string) (uint16, error) {
	s = strings.ToLower(s)
	if len(s) == 1 {
		c := s[0]
		if c >= 'a' && c <= 'z' {
			return uint16(c - 'a' + 'A'), nil
		}
		if c >= '0' && c <= '9' {
			return uint16(c), nil
		}
	}
	keys := map[string]uint16{"backspace": 8, "tab": 9, "enter": 13, "shift": 0x10, "ctrl": 0x11, "alt": 0x12, "escape": 27, "space": 32, "pageup": 0x21, "pagedown": 0x22, "end": 0x23, "home": 0x24, "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28, "insert": 0x2D, "delete": 0x2E, "meta": 0x5B, "playPause": 0xB3, "playpause": 0xB3, "stop": 0xB2, "next": 0xB0, "previous": 0xB1, "volumemute": 0xAD, "volumedown": 0xAE, "volumeup": 0xAF}
	if k, ok := keys[s]; ok {
		return k, nil
	}
	var f int
	if _, e := fmt.Sscanf(s, "f%d", &f); e == nil && f >= 1 && f <= 24 && s == fmt.Sprint("f", f) {
		return uint16(0x6F + f), nil
	}
	return 0, invalid("Unsupported key; use keyboard.text for Unicode text")
}

type Desktop struct {
	X      int32 `json:"x"`
	Y      int32 `json:"y"`
	Width  int32 `json:"width"`
	Height int32 `json:"height"`
}

func desktopGeometry() Desktop {
	metric := func(i uintptr) int32 { r, _, _ := user32.NewProc("GetSystemMetrics").Call(i); return int32(r) }
	return Desktop{metric(76), metric(77), metric(78), metric(79)}
}
func inputCommand(c Command, h *heldInput) (any, error) {
	var a []nativeInput
	var releaseKey uint16
	var releaseButton string
	switch c.Op {
	case "input.keepAlive":
		return map[string]bool{"applied": true}, nil
	case "input.release":
		h.release()
		return map[string]bool{"applied": true}, nil
	case "mouse.move":
		if c.X != nil && c.Y != nil && c.DX == nil && c.DY == nil {
			d := desktopGeometry()
			if *c.X < d.X || *c.Y < d.Y || *c.X >= d.X+d.Width || *c.Y >= d.Y+d.Height {
				return nil, invalid("Absolute point is outside virtual desktop")
			}
			// Address the center of the physical pixel; edge normalization can land
			// one pixel short because Windows maps using 65536, not 65535.
			x := int32(min(int64(65535), (int64(*c.X-d.X)*65536+32768)/int64(max(d.Width, 1))))
			y := int32(min(int64(65535), (int64(*c.Y-d.Y)*65536+32768)/int64(max(d.Height, 1))))
			a = append(a, mouseEvent(x, y, 0, 0x8000|0x4000|1))
		} else if c.DX != nil && c.DY != nil && c.X == nil && c.Y == nil {
			if abs32(*c.DX) > 10000 || abs32(*c.DY) > 10000 {
				return nil, invalid("Movement delta exceeds 10000")
			}
			a = append(a, mouseEvent(*c.DX, *c.DY, 0, 1))
		} else {
			return nil, invalid("Supply x/y OR dx/dy together")
		}
	case "mouse.button":
		down, up, e := buttonFlags(c.Button)
		if e != nil {
			return nil, e
		}
		switch c.Action {
		case "", "click":
			if h.buttons[c.Button] {
				return nil, invalid("Release the held button before clicking")
			}
			a = append(a, mouseEvent(0, 0, 0, down), mouseEvent(0, 0, 0, up))
		case "down":
			if h.buttons[c.Button] {
				return map[string]bool{"applied": true}, nil
			}
			h.buttons[c.Button] = true
			a = append(a, mouseEvent(0, 0, 0, down))
		case "up":
			if !h.buttons[c.Button] {
				return nil, invalid("This controller is not holding that button")
			}
			releaseButton = c.Button
			a = append(a, mouseEvent(0, 0, 0, up))
		default:
			return nil, invalid("action must be click, down or up")
		}
	case "mouse.scroll":
		if c.DX == nil && c.DY == nil {
			return nil, invalid("dx or dy is required")
		}
		if c.DY != nil {
			if abs32(*c.DY) > 12000 {
				return nil, invalid("Scroll delta exceeds 12000")
			}
			a = append(a, mouseEvent(0, 0, uint32(*c.DY), 0x800))
		}
		if c.DX != nil {
			if abs32(*c.DX) > 12000 {
				return nil, invalid("Scroll delta exceeds 12000")
			}
			a = append(a, mouseEvent(0, 0, uint32(*c.DX), 0x1000))
		}
	case "keyboard.text":
		units := utf16.Encode([]rune(c.Text))
		if len(units) == 0 || len(units) > 2048 {
			return nil, invalid("text must contain 1..2048 UTF-16 units")
		}
		for _, u := range units {
			a = append(a, keyEvent(0, u, 4), keyEvent(0, u, 4|2))
		}
	case "keyboard.key", "media.key":
		k, e := virtualKey(c.Key)
		if e != nil {
			return nil, e
		}
		if c.Op == "media.key" && k < 0xAD {
			return nil, invalid("Use playPause, next, previous, stop, volumeUp, volumeDown or volumeMute")
		}
		if len(c.Modifiers) > 4 {
			return nil, invalid("At most four modifiers")
		}
		var modifiers []uint16
		seen := map[uint16]bool{}
		for _, m := range c.Modifiers {
			v, e := virtualKey(m)
			if e != nil || !(v == 0x10 || v == 0x11 || v == 0x12 || v == 0x5B) || seen[v] || h.keys[v] {
				return nil, invalid("Modifiers must be unique shift/ctrl/alt/meta and not already held")
			}
			seen[v] = true
			modifiers = append(modifiers, v)
		}
		if len(modifiers) > 0 && c.Action != "" && c.Action != "press" {
			return nil, invalid("Modifiers require action press")
		}
		for _, v := range modifiers {
			a = append(a, keyEvent(v, 0, keyFlags(v)))
		}
		switch c.Action {
		case "", "press":
			if h.keys[k] {
				return nil, invalid("Key is already held")
			}
			a = append(a, keyEvent(k, 0, keyFlags(k)), keyEvent(k, 0, keyFlags(k)|2))
		case "down":
			if h.keys[k] {
				return map[string]bool{"applied": true}, nil
			}
			h.keys[k] = true
			a = append(a, keyEvent(k, 0, keyFlags(k)))
		case "up":
			if !h.keys[k] {
				return nil, invalid("This controller is not holding that key")
			}
			releaseKey = k
			a = append(a, keyEvent(k, 0, keyFlags(k)|2))
		default:
			return nil, invalid("action must be press, down or up")
		}
		for i := len(modifiers) - 1; i >= 0; i-- {
			v := modifiers[i]
			a = append(a, keyEvent(v, 0, keyFlags(v)|2))
		}
	}
	if c.Action == "down" {
		if e := h.persist(); e != nil {
			h.release()
			return nil, fmt.Errorf("Could not persist held-input recovery state")
		}
	}
	if e := sendInputs(a); e != nil {
		// A partial SendInput must also release temporary shortcut modifiers.
		for _, n := range a {
			if n.Kind == 1 {
				k := *(*keyInput)(unsafe.Pointer(&n.Data[0]))
				if k.Flags&2 == 0 {
					_ = sendInputs([]nativeInput{keyEvent(k.VK, k.Scan, k.Flags|2)})
				}
			}
		}
		h.release()
		return nil, e
	}
	if releaseKey != 0 {
		delete(h.keys, releaseKey)
	}
	if releaseButton != "" {
		delete(h.buttons, releaseButton)
	}
	if releaseButton != "" || releaseKey != 0 {
		_ = h.persist()
	}
	return map[string]bool{"applied": true}, nil
}
func abs32(i int32) int64 {
	v := int64(i)
	if v < 0 {
		return -v
	}
	return v
}

type rect struct{ Left, Top, Right, Bottom int32 }
type monitorInfo struct {
	Size          uint32
	Monitor, Work rect
	Flags         uint32
	Device        [32]uint16
}
type physicalMonitor struct {
	Handle      uintptr
	Description [128]uint16
}
type Display struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Backend    string   `json:"backend"`
	Bounds     *Desktop `json:"bounds,omitempty"`
	Brightness *float64 `json:"brightness,omitempty"`
	Supported  bool     `json:"supported"`
	Reason     string   `json:"reason,omitempty"`
}

type monitorContext struct {
	fn    func(string, physicalMonitor, Desktop) error
	first error
}

var monitorEnumMu sync.Mutex
var monitorCallback = syscall.NewCallback(enumMonitor)
var activeMonitorContext *monitorContext

func enumMonitor(h, hdc, r, l uintptr) uintptr {
	ctx := activeMonitorContext
	var info monitorInfo
	info.Size = uint32(unsafe.Sizeof(info))
	ok, _, _ := user32.NewProc("GetMonitorInfoW").Call(h, uintptr(unsafe.Pointer(&info)))
	if ok == 0 {
		return 1
	}
	var count uint32
	ok, _, _ = dxva2.NewProc("GetNumberOfPhysicalMonitorsFromHMONITOR").Call(h, uintptr(unsafe.Pointer(&count)))
	if ok == 0 || count == 0 || count > 32 {
		return 1
	}
	ps := make([]physicalMonitor, count)
	ok, _, _ = dxva2.NewProc("GetPhysicalMonitorsFromHMONITOR").Call(h, uintptr(count), uintptr(unsafe.Pointer(&ps[0])))
	if ok == 0 {
		return 1
	}
	defer dxva2.NewProc("DestroyPhysicalMonitors").Call(uintptr(count), uintptr(unsafe.Pointer(&ps[0])))
	for i, p := range ps {
		id := fmt.Sprintf("%s:%d", windows.UTF16ToString(info.Device[:]), i)
		d := Desktop{info.Monitor.Left, info.Monitor.Top, info.Monitor.Right - info.Monitor.Left, info.Monitor.Bottom - info.Monitor.Top}
		if e := ctx.fn(id, p, d); e != nil && ctx.first == nil {
			ctx.first = e
		}
	}
	return 1
}
func withMonitors(fn func(string, physicalMonitor, Desktop) error) error {
	monitorEnumMu.Lock()
	defer monitorEnumMu.Unlock()
	ctx := &monitorContext{fn: fn}
	activeMonitorContext = ctx
	defer func() { activeMonitorContext = nil }()
	ok, _, e := user32.NewProc("EnumDisplayMonitors").Call(0, 0, monitorCallback, 0)
	runtime.KeepAlive(ctx)
	if ok == 0 {
		return winError("EnumDisplayMonitors", e)
	}
	return ctx.first
}
func monitorBrightness(p physicalMonitor) (uint32, uint32, uint32, bool, error) {
	var lo, cur, hi uint32
	r, _, _ := dxva2.NewProc("GetMonitorBrightness").Call(p.Handle, uintptr(unsafe.Pointer(&lo)), uintptr(unsafe.Pointer(&cur)), uintptr(unsafe.Pointer(&hi)))
	if r != 0 && hi > lo {
		return lo, cur, hi, false, nil
	}
	var kind uint32
	r, _, e := dxva2.NewProc("GetVCPFeatureAndVCPFeatureReply").Call(p.Handle, 0x10, uintptr(unsafe.Pointer(&kind)), uintptr(unsafe.Pointer(&cur)), uintptr(unsafe.Pointer(&hi)))
	if r != 0 && hi > 0 {
		return 0, cur, hi, true, nil
	}
	return 0, 0, 0, false, winError("Monitor does not report DDC/CI brightness; check its on-screen DDC/CI setting", e)
}
func listDisplays() ([]Display, error) {
	var displays []Display
	e := withMonitors(func(id string, p physicalMonitor, d Desktop) error {
		lo, cur, hi, _, err := monitorBrightness(p)
		v := Display{ID: id, Name: windows.UTF16ToString(p.Description[:]), Backend: "ddc-ci", Bounds: &d, Supported: err == nil}
		if err == nil {
			pct := float64(cur-lo) * 100 / float64(hi-lo)
			v.Brightness = &pct
		} else {
			v.Reason = err.Error()
		}
		displays = append(displays, v)
		return nil
	})
	if e != nil {
		return nil, e
	}
	internal, e := wmiDisplays("", nil)
	if e == nil {
		displays = append(displays, internal...)
	}
	if displays == nil {
		displays = []Display{}
	}
	return displays, nil
}
func setDisplay(id string, level float64) (any, error) {
	if strings.HasPrefix(id, "wmi:") {
		a, e := wmiDisplays(id, &level)
		if e != nil {
			return nil, e
		}
		if len(a) == 0 {
			return nil, &APIError{"display_unavailable", "Display no longer connected; refresh displays.list"}
		}
		return a[0], nil
	}
	found := false
	var result Display
	err := withMonitors(func(mid string, p physicalMonitor, d Desktop) error {
		if mid != id {
			return nil
		}
		found = true
		lo, _, hi, vcp, e := monitorBrightness(p)
		if e != nil {
			return &APIError{"unsupported", e.Error()}
		}
		raw := lo + uint32(math.Round(level*float64(hi-lo)/100))
		var ok uintptr
		if vcp {
			ok, _, e = dxva2.NewProc("SetVCPFeature").Call(p.Handle, 0x10, uintptr(raw))
		} else {
			ok, _, e = dxva2.NewProc("SetMonitorBrightness").Call(p.Handle, uintptr(raw))
		}
		if ok == 0 {
			return winError("Set monitor brightness", e)
		}
		actual := float64(raw-lo) * 100 / float64(hi-lo)
		result = Display{ID: mid, Name: windows.UTF16ToString(p.Description[:]), Backend: "ddc-ci", Bounds: &d, Brightness: &actual, Supported: true}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, &APIError{"display_unavailable", "Display no longer connected; refresh displays.list"}
	}
	return result, nil
}
func wmiDisplays(target string, level *float64) ([]Display, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if e := ole.CoInitializeEx(0, ole.COINIT_MULTITHREADED); e != nil {
		return nil, e
	}
	defer ole.CoUninitialize()
	obj, e := oleutil.CreateObject("WbemScripting.SWbemLocator")
	if e != nil {
		return nil, e
	}
	defer obj.Release()
	loc, e := obj.QueryInterface(ole.IID_IDispatch)
	if e != nil {
		return nil, e
	}
	defer loc.Release()
	sv, e := oleutil.CallMethod(loc, "ConnectServer", ".", "root\\wmi")
	if e != nil {
		return nil, e
	}
	defer sv.Clear()
	svc := sv.ToIDispatch()
	q := "SELECT * FROM WmiMonitorBrightness WHERE Active = TRUE"
	if level != nil {
		q = "SELECT * FROM WmiMonitorBrightnessMethods WHERE Active = TRUE"
	}
	rv, e := oleutil.CallMethod(svc, "ExecQuery", q)
	if e != nil {
		return nil, e
	}
	defer rv.Clear()
	var ds []Display
	e = oleutil.ForEach(rv.ToIDispatch(), func(v *ole.VARIANT) error {
		d := v.ToIDispatch()
		iv, e := oleutil.GetProperty(d, "InstanceName")
		if e != nil {
			return e
		}
		instance := iv.ToString()
		iv.Clear()
		id := "wmi:" + base64.RawURLEncoding.EncodeToString([]byte(instance))
		if target != "" && target != id {
			return nil
		}
		var val float64
		if level != nil {
			r, e := oleutil.CallMethod(d, "WmiSetBrightness", uint32(0), uint8(math.Round(*level)))
			if e != nil {
				return e
			}
			defer r.Clear()
			if n, ok := r.Value().(int32); ok && n != 0 {
				return fmt.Errorf("WmiSetBrightness returned %d", n)
			}
			val = *level
		} else {
			b, e := oleutil.GetProperty(d, "CurrentBrightness")
			if e != nil {
				return e
			}
			switch n := b.Value().(type) {
			case uint8:
				val = float64(n)
			case int32:
				val = float64(n)
			default:
				b.Clear()
				return errors.New("Unexpected WMI brightness type")
			}
			b.Clear()
		}
		ds = append(ds, Display{ID: id, Name: instance, Backend: "wmi", Brightness: &val, Supported: true})
		return nil
	})
	return ds, e
}
