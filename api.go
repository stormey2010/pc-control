package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

type Command struct {
	ID        json.RawMessage `json:"id,omitempty"`
	Op        string          `json:"op"`
	Level     *float64        `json:"level,omitempty"`
	Muted     *bool           `json:"muted,omitempty"`
	Display   string          `json:"display,omitempty"`
	X         *int32          `json:"x,omitempty"`
	Y         *int32          `json:"y,omitempty"`
	DX        *int32          `json:"dx,omitempty"`
	DY        *int32          `json:"dy,omitempty"`
	Button    string          `json:"button,omitempty"`
	Action    string          `json:"action,omitempty"`
	Text      string          `json:"text,omitempty"`
	Key       string          `json:"key,omitempty"`
	Modifiers []string        `json:"modifiers,omitempty"`
	Confirm   string          `json:"confirm,omitempty"`
	Delay     *int            `json:"delaySeconds,omitempty"`
}
type APIError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *APIError) Error() string { return e.Message }
func invalid(s string) error      { return &APIError{"invalid_command", s} }

type Reply struct {
	ID     json.RawMessage `json:"id,omitempty"`
	OK     bool            `json:"ok"`
	Result any             `json:"result,omitempty"`
	Error  *APIError       `json:"error,omitempty"`
}

func response(c Command, v any, err error) Reply {
	r := Reply{ID: c.ID, OK: err == nil, Result: v}
	if err != nil {
		r.Result = nil
		var a *APIError
		if errors.As(err, &a) {
			r.Error = a
		} else {
			r.Error = &APIError{"action_failed", err.Error()}
		}
	}
	return r
}

type server struct {
	pairingMu      sync.Mutex
	pairingRequest *pairRequest
	pairingLast    time.Time
	cfg            Config
	dataDir        string
	tokenHash      [32]byte
	started        time.Time
	socket         atomic.Bool
	slots          chan struct{}
	input          sync.Mutex
	audio          sync.Mutex
	displays       sync.Mutex
	power          sync.Mutex
	shutdown       *time.Timer
	shutdownAt     time.Time
	authMu         sync.Mutex
	attempts       map[string]authWindow
}
type authWindow struct {
	start time.Time
	count int
}

func newServer(cfg Config) *server {
	return &server{cfg: cfg, tokenHash: sha256.Sum256([]byte(cfg.Token)), started: time.Now(), slots: make(chan struct{}, 8), attempts: make(map[string]authWindow)}
}
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func (s *server) localOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		ip := net.ParseIP(host)
		if ip == nil || !(ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()) {
			http.Error(w, "Local network only", 403)
			return
		}
		if r.Header.Get("Origin") != "" {
			http.Error(w, "Native clients only", 403)
			return
		}
		next.ServeHTTP(w, r)
	})
}
func (s *server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		s.authMu.Lock()
		a := s.attempts[host]
		if time.Since(a.start) > time.Minute {
			a = authWindow{start: time.Now()}
		}
		blocked := a.count >= 20
		s.authMu.Unlock()
		if blocked {
			http.Error(w, "Too many authentication failures", 429)
			return
		}
		h := r.Header.Get("Authorization")
		candidate := sha256.Sum256([]byte(strings.TrimPrefix(h, "Bearer ")))
		if !strings.HasPrefix(h, "Bearer ") || subtle.ConstantTimeCompare(candidate[:], s.tokenHash[:]) != 1 {
			s.authMu.Lock()
			if len(s.attempts) >= 256 {
				clear(s.attempts)
			}
			a.count++
			s.attempts[host] = a
			s.authMu.Unlock()
			w.Header().Set("WWW-Authenticate", "Bearer")
			writeJSON(w, 401, Reply{Error: &APIError{"unauthorized", "A valid pairing token is required"}})
			return
		}
		next(w, r)
	}
}
func (s *server) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{"ok": true, "service": "pc-control", "version": version})
}
func (s *server) info(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, s.metadata()) }
func (s *server) diagnostics(w http.ResponseWriter, r *http.Request) {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		http.Error(w, "Loopback only", 403)
		return
	}
	b := make([]byte, 1<<20)
	n := runtime.Stack(b, true)
	w.Header().Set("Content-Type", "text/plain")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(b[:n])
}

// Native APIs can hang inside third-party audio/display/input drivers. A stuck
// call must not leave a healthy-looking but unusable worker holding locks.
func nativeDeadline() func() {
	timer := time.AfterFunc(8*time.Second, func() { log.Print("Native control exceeded 8 seconds; exiting for automatic recovery"); os.Exit(1) })
	return func() { timer.Stop() }
}
func (s *server) metadata() any {
	return map[string]any{"version": version, "protocolVersion": 1, "deviceId": s.cfg.DeviceID, "name": s.cfg.Name, "uptimeSeconds": int(time.Since(s.started).Seconds()), "desktop": desktopGeometry(), "capabilities": []string{"audio", "brightness.ddc-ci", "brightness.wmi", "mouse", "keyboard.unicode", "media", "shutdown", "lock"}, "maxMessageBytes": 16384, "maxWebSockets": 1, "brightness": "Call displays.list to inspect actual hardware support"}
}
func decodeCommand(b []byte) (Command, error) {
	var c Command
	d := json.NewDecoder(strings.NewReader(string(b)))
	d.DisallowUnknownFields()
	if err := d.Decode(&c); err != nil {
		return c, invalid("Invalid JSON or unknown command field")
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return c, invalid("One JSON object is required")
	}
	if c.Op == "" {
		return c, invalid("op is required")
	}
	if len(c.ID) > 128 {
		return c, invalid("id is too long")
	}
	if len(c.ID) > 0 {
		var id any
		_ = json.Unmarshal(c.ID, &id)
		switch id.(type) {
		case string, float64:
		default:
			return c, invalid("id must be a string or number")
		}
	}
	return c, nil
}
func (s *server) command(w http.ResponseWriter, r *http.Request) {
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	default:
		writeJSON(w, 429, Reply{Error: &APIError{"busy", "Too many concurrent requests"}})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16384)
	b, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, 413, response(Command{}, nil, invalid("Message exceeds 16384 bytes")))
		return
	}
	c, err := decodeCommand(b)
	var v any
	if err == nil {
		v, err = s.execute(c, false, nil)
	}
	status := 200
	if err != nil {
		status = 400
	}
	writeJSON(w, status, response(c, v, err))
}
func lane(op string) int {
	if strings.HasPrefix(op, "audio.") {
		return 0
	}
	if op == "displays.list" || op == "display.set" {
		return 1
	}
	return 2
}
func isInput(op string) bool {
	return strings.HasPrefix(op, "input.") || strings.HasPrefix(op, "mouse.") || strings.HasPrefix(op, "keyboard.") || op == "media.key"
}
func (s *server) websocket(w http.ResponseWriter, r *http.Request) {
	if !s.socket.CompareAndSwap(false, true) {
		writeJSON(w, 409, Reply{Error: &APIError{"input_busy", "A controller is already connected"}})
		return
	}
	defer s.socket.Store(false)
	conn, err := (&websocket.Upgrader{ReadBufferSize: 4096, WriteBufferSize: 4096, CheckOrigin: func(r *http.Request) bool { return r.Header.Get("Origin") == "" }, EnableCompression: false}).Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()
	conn.SetReadLimit(16384)
	done := make(chan struct{})
	out := make(chan any, 128)
	var workers sync.WaitGroup
	emit := func(v any) bool {
		select {
		case out <- v:
			return true
		case <-done:
			return false
		default:
			conn.Close()
			return false
		}
	}
	workers.Add(1)
	go func() {
		defer workers.Done()
		for {
			select {
			case v := <-out:
				_ = conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
				if conn.WriteJSON(v) != nil {
					conn.Close()
					return
				}
			case <-done:
				return
			}
		}
	}()
	// Independent slow-control lanes keep DDC/CI hardware calls off the touchpad path.
	queues := []chan Command{make(chan Command, 16), make(chan Command, 16), make(chan Command, 16)}
	for _, q := range queues {
		workers.Add(1)
		go func(q chan Command) {
			defer workers.Done()
			for {
				select {
				case c := <-q:
					select {
					case <-done:
						return
					default:
					}
					v, e := s.execute(c, true, nil)
					if !emit(response(c, v, e)) {
						return
					}
				case <-done:
					return
				}
			}
		}(q)
	}
	held := newHeldInput()
	if s.dataDir != "" {
		held.savePath = filepath.Join(s.dataDir, "held-input.json")
	}
	var lastInput atomic.Int64
	lastInput.Store(time.Now().UnixNano())
	workers.Add(1)
	go func() {
		defer workers.Done()
		tick := time.NewTicker(500 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-tick.C:
				if time.Since(time.Unix(0, lastInput.Load())) > 2*time.Second {
					s.input.Lock()
					held.release()
					s.input.Unlock()
				}
			case <-done:
				return
			}
		}
	}()
	defer func() {
		close(done)
		conn.Close()
		s.input.Lock()
		held.release()
		s.input.Unlock()
		workers.Wait()
	}()
	_ = conn.SetReadDeadline(time.Now().Add(45 * time.Second))
	conn.SetPongHandler(func(string) error { return conn.SetReadDeadline(time.Now().Add(45 * time.Second)) })
	emit(map[string]any{"event": "ready", "info": s.metadata()})
	for {
		kind, b, e := conn.ReadMessage()
		if e != nil {
			return
		}
		_ = conn.SetReadDeadline(time.Now().Add(45 * time.Second))
		if kind != websocket.TextMessage && kind != websocket.BinaryMessage {
			emit(response(Command{}, nil, invalid("JSON messages required")))
			continue
		}
		c, e := decodeCommand(b)
		if e != nil {
			emit(response(c, nil, e))
			continue
		}
		if isInput(c.Op) || c.Op == "ping" {
			if isInput(c.Op) {
				lastInput.Store(time.Now().UnixNano())
			}
			v, e := s.execute(c, true, held)
			if !emit(response(c, v, e)) {
				return
			}
		} else {
			select {
			case queues[lane(c.Op)] <- c:
			default:
				emit(response(c, nil, &APIError{"busy", "Control queue full; reduce update rate"}))
			}
		}
	}
}
func (s *server) execute(c Command, stream bool, held *heldInput) (any, error) {
	switch c.Op {
	case "ping":
		return map[string]any{"time": time.Now().UTC()}, nil
	case "info":
		return s.metadata(), nil
	case "audio.get", "audio.set":
		if c.Op == "audio.set" {
			if c.Level == nil && c.Muted == nil {
				return nil, invalid("level or muted is required")
			}
			if c.Level != nil && (*c.Level < 0 || *c.Level > 100) {
				return nil, invalid("level must be 0..100")
			}
		}
		s.audio.Lock()
		defer s.audio.Unlock()
		defer nativeDeadline()()
		return audioControl(c)
	case "displays.list":
		s.displays.Lock()
		defer s.displays.Unlock()
		defer nativeDeadline()()
		return listDisplays()
	case "display.set":
		if c.Display == "" || c.Level == nil || *c.Level < 0 || *c.Level > 100 {
			return nil, invalid("display and level 0..100 are required")
		}
		s.displays.Lock()
		defer s.displays.Unlock()
		defer nativeDeadline()()
		return setDisplay(c.Display, *c.Level)
	case "input.keepAlive", "input.release", "mouse.move", "mouse.button", "mouse.scroll", "keyboard.text", "keyboard.key", "media.key":
		s.input.Lock()
		defer s.input.Unlock()
		defer nativeDeadline()()
		if !stream && s.socket.Load() {
			return nil, &APIError{"input_busy", "Use the connected WebSocket for input"}
		}
		if held == nil {
			if c.Action == "down" || c.Action == "up" {
				return nil, invalid("Held input requires a WebSocket")
			}
			held = newHeldInput()
			defer held.release()
		}
		return inputCommand(c, held)
	case "system.shutdown":
		if c.Confirm != "shutdown" {
			return nil, invalid("confirm must be shutdown")
		}
		delay := 30
		if c.Delay != nil {
			delay = *c.Delay
		}
		if delay < 5 || delay > 300 {
			return nil, invalid("delaySeconds must be 5..300")
		}
		s.power.Lock()
		defer s.power.Unlock()
		if s.shutdown != nil {
			return nil, &APIError{"already_pending", "Shutdown already scheduled"}
		}
		s.shutdownAt = time.Now().Add(time.Duration(delay) * time.Second)
		s.shutdown = time.AfterFunc(time.Duration(delay)*time.Second, func() {
			s.power.Lock()
			defer s.power.Unlock()
			cmd := exec.Command("shutdown.exe", "/s", "/t", "0")
			cmd.SysProcAttr = hiddenProcess()
			_ = cmd.Run()
			s.shutdown = nil
			s.shutdownAt = time.Time{}
		})
		return map[string]any{"scheduledAt": s.shutdownAt, "delaySeconds": delay}, nil
	case "system.cancelShutdown":
		s.power.Lock()
		defer s.power.Unlock()
		cancelled := s.shutdown != nil && s.shutdown.Stop()
		s.shutdown = nil
		s.shutdownAt = time.Time{}
		return map[string]bool{"cancelled": cancelled}, nil
	case "system.status":
		s.power.Lock()
		defer s.power.Unlock()
		return map[string]any{"shutdownPending": s.shutdown != nil, "scheduledAt": s.shutdownAt}, nil
	case "system.lock":
		return nil, lockDesktop()
	default:
		return nil, invalid(fmt.Sprintf("Unknown operation %q", c.Op))
	}
}
