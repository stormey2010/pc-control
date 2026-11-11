package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"testing/synctest"
	"time"
	"unsafe"

	"github.com/gorilla/websocket"
)

func testServer() *server {
	return newServer(Config{Port: 48180, Token: strings.Repeat("t", 43), DeviceID: "0123456789abcdef", Name: "test"})
}
func TestStrictJSON(t *testing.T) {
	for _, b := range []string{`{}`, `null`, `[]`, `{"op":"ping","id":{}}`, `{"op":"ping","id":null}`, `{"op":"ping","typo":1}`, `{"op":"ping"} {}`, `{"op":"ping","dx":1.5}`, `{"op":"ping","id":"` + strings.Repeat("x", 129) + `"}`} {
		if _, e := decodeCommand([]byte(b)); e == nil {
			t.Errorf("accepted malformed command %s", b)
		}
	}
	c, e := decodeCommand([]byte(`{"id":12,"op":"ping"}`))
	if e != nil || c.Op != "ping" {
		t.Fatal("valid command rejected")
	}
}
func TestAuthenticationAndNetworkBoundary(t *testing.T) {
	s := testServer()
	handler := s.localOnly(s.auth(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	cases := []struct {
		name, remote, token, origin string
		status                      int
	}{{"missing", "192.168.4.10:1", "", "", 401}, {"wrong", "192.168.4.10:1", "wrong", "", 401}, {"valid", "192.168.4.10:1", s.cfg.Token, "", 204}, {"browser", "192.168.4.10:1", s.cfg.Token, "https://hostile.example", 403}, {"public", "8.8.8.8:1", s.cfg.Token, "", 403}, {"loopback", "127.0.0.1:1", s.cfg.Token, "", 204}, {"ipv6", "[fd00::1]:1", s.cfg.Token, "", 204}}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequest("POST", "https://localhost/v1/command?token="+s.cfg.Token, nil)
			r.RemoteAddr = c.remote
			if c.token != "" {
				r.Header.Set("Authorization", "Bearer "+c.token)
			}
			r.Header.Set("Origin", c.origin)
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != c.status {
				t.Fatalf("got %d want %d", w.Code, c.status)
			}
		})
	}
}
func TestAuthenticationThrottling(t *testing.T) {
	s := testServer()
	h := s.auth(func(w http.ResponseWriter, r *http.Request) {})
	for i := 0; i < 21; i++ {
		r := httptest.NewRequest("GET", "https://localhost/v1/info", nil)
		r.RemoteAddr = "192.168.4.20:1"
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if i == 20 && w.Code != 429 {
			t.Fatal("failed auth not throttled")
		}
	}
}
func TestCommandValidation(t *testing.T) {
	s := testServer()
	for _, b := range []string{`{"op":"nope"}`, `{"op":"audio.set"}`, `{"op":"audio.set","level":-1}`, `{"op":"audio.set","level":101}`, `{"op":"display.set","display":"x"}`, `{"op":"display.set","display":"x","level":101}`, `{"op":"mouse.move","dx":1}`, `{"op":"mouse.move","x":1,"y":2,"dx":1,"dy":2}`, `{"op":"mouse.move","dx":-2147483648,"dy":0}`, `{"op":"mouse.button","button":"bad"}`, `{"op":"mouse.button","button":"left","action":"down"}`, `{"op":"mouse.scroll","dy":12001}`, `{"op":"keyboard.text"}`, `{"op":"keyboard.key","key":"unknown"}`, `{"op":"keyboard.key","key":"a","modifiers":["ctrl","ctrl"]}`, `{"op":"media.key","key":"a"}`, `{"op":"system.shutdown"}`, `{"op":"system.shutdown","confirm":"shutdown","delaySeconds":0}`} {
		c, e := decodeCommand([]byte(b))
		if e != nil {
			t.Fatal(e)
		}
		if _, e = s.execute(c, false, nil); e == nil {
			t.Errorf("accepted invalid command %s", b)
		}
	}
}
func TestShutdownScheduleAndCancel(t *testing.T) {
	s := testServer()
	delay := 300
	defer s.execute(Command{Op: "system.cancelShutdown"}, false, nil)
	if _, e := s.execute(Command{Op: "system.shutdown", Confirm: "shutdown", Delay: &delay}, false, nil); e != nil {
		t.Fatal(e)
	}
	if _, e := s.execute(Command{Op: "system.shutdown", Confirm: "shutdown", Delay: &delay}, false, nil); e == nil {
		t.Fatal("duplicate shutdown accepted")
	}
	v, e := s.execute(Command{Op: "system.cancelShutdown"}, false, nil)
	if e != nil || !v.(map[string]bool)["cancelled"] {
		t.Fatal("shutdown cancellation failed")
	}
	if s.shutdown != nil {
		t.Fatal("shutdown timer retained")
	}
}
func TestRequestSizeLimit(t *testing.T) {
	s := testServer()
	r := httptest.NewRequest("POST", "/v1/command", strings.NewReader(strings.Repeat("x", 17000)))
	w := httptest.NewRecorder()
	s.command(w, r)
	if w.Code != 413 {
		t.Fatalf("got %d", w.Code)
	}
}
func TestNativeLayouts(t *testing.T) {
	if unsafe.Sizeof(nativeInput{}) != 40 || unsafe.Sizeof(mouseInput{}) != 32 || unsafe.Sizeof(keyInput{}) != 24 || unsafe.Sizeof(physicalMonitor{}) != 264 || unsafe.Sizeof(monitorInfo{}) != 104 {
		t.Fatal("Windows x64 ABI layout mismatch")
	}
}
func TestCertificateAndCredentialsPersist(t *testing.T) {
	dir := t.TempDir()
	a, cert, e := loadConfig(dir)
	if e != nil {
		t.Fatal(e)
	}
	b, cert2, e := loadConfig(dir)
	if e != nil {
		t.Fatal(e)
	}
	if a.Token != b.Token || string(cert.Certificate[0]) != string(cert2.Certificate[0]) {
		t.Fatal("pairing changed on restart")
	}
	var connection Connection
	data, e := os.ReadFile(filepath.Join(dir, "connection.json"))
	if e != nil {
		t.Fatal(e)
	}
	if e = json.Unmarshal(data, &connection); e != nil {
		t.Fatal(e)
	}
	sum := sha256.Sum256(cert.Certificate[0])
	if connection.CertificateSHA256 != hex.EncodeToString(sum[:]) {
		t.Fatal("wrong certificate fingerprint")
	}
}
func TestWebSocketProtocolAndExclusivity(t *testing.T) {
	s := testServer()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", s.auth(s.websocket))
	mux.HandleFunc("/v1/command", s.auth(s.command))
	srv := httptest.NewServer(s.localOnly(mux))
	defer srv.Close()
	h := http.Header{"Authorization": []string{"Bearer " + s.cfg.Token}}
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1/ws"
	c, _, e := websocket.DefaultDialer.Dial(url, h)
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	var ready map[string]any
	if e = c.ReadJSON(&ready); e != nil || ready["event"] != "ready" {
		t.Fatal("missing ready event")
	}
	other, r, e := websocket.DefaultDialer.Dial(url, h)
	if other != nil {
		other.Close()
	}
	if e == nil || r.StatusCode != 409 {
		t.Fatal("second controller accepted")
	}
	r.Body.Close()
	for i := 0; i < 100; i++ {
		if e = c.WriteJSON(map[string]any{"op": "ping", "id": i}); e != nil {
			t.Fatal(e)
		}
		var reply Reply
		if e = c.ReadJSON(&reply); e != nil || !reply.OK || string(reply.ID) != strings.TrimSpace(string(mustJSON(i))) {
			t.Fatal("ping reply mismatch")
		}
	}
	c.WriteMessage(websocket.TextMessage, []byte(`{"op":"ping","bad":true}`))
	var bad Reply
	c.ReadJSON(&bad)
	if bad.OK || bad.Error == nil {
		t.Fatal("malformed WebSocket accepted")
	}
	req, _ := http.NewRequest("POST", srv.URL+"/v1/command", strings.NewReader(`{"op":"mouse.move","dx":0,"dy":0}`))
	req.Header = h
	rr, e := http.DefaultClient.Do(req)
	if e != nil {
		t.Fatal(e)
	}
	body, _ := io.ReadAll(rr.Body)
	rr.Body.Close()
	if !strings.Contains(string(body), "input_busy") {
		t.Fatal("REST input bypassed controller lock")
	}
	c.Close()
	deadline := time.Now().Add(2 * time.Second)
	for s.socket.Load() && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if s.socket.Load() {
		t.Fatal("controller lock was not released")
	}
	// Repeated reconnects must not leave the controller locked.
	for i := 0; i < 20; i++ {
		c, _, e = websocket.DefaultDialer.Dial(url, h)
		if e != nil {
			t.Fatal(e)
		}
		c.ReadJSON(&ready)
		c.Close()
		deadline = time.Now().Add(time.Second)
		for s.socket.Load() && time.Now().Before(deadline) {
			time.Sleep(time.Millisecond)
		}
	}
}
func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }

func TestBoundedLogs(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.log")
	f, e := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if e != nil {
		t.Fatal(e)
	}
	w := &rotatingLog{f: f, path: path, max: 100}
	defer w.Close()
	for i := 0; i < 30; i++ {
		if _, e = w.Write([]byte(strings.Repeat("x", 30))); e != nil {
			t.Fatal(e)
		}
	}
	for _, p := range []string{path, path + ".old"} {
		st, e := os.Stat(p)
		if e != nil || st.Size() > 100 {
			t.Fatal("log bound exceeded")
		}
	}
}
func TestHeldInputRecoveryState(t *testing.T) {
	dir := t.TempDir()
	h := newHeldInput()
	h.savePath = filepath.Join(dir, "held-input.json")
	h.keys[0x10] = true
	h.buttons["left"] = true
	if e := h.persist(); e != nil {
		t.Fatal(e)
	}
	h.keys[0x11] = true
	if e := h.persist(); e != nil {
		t.Fatal("replacement write failed", e)
	}
	var state heldState
	b, e := os.ReadFile(h.savePath)
	if e != nil {
		t.Fatal(e)
	}
	if e = json.Unmarshal(b, &state); e != nil || len(state.Keys) != 2 || len(state.Buttons) != 1 {
		t.Fatal("held state mismatch")
	}
	clear(h.keys)
	clear(h.buttons)
	if e = h.persist(); e != nil {
		t.Fatal(e)
	}
	if _, e = os.Stat(h.savePath); !os.IsNotExist(e) {
		t.Fatal("released state retained")
	}
}

func TestNativeDeadlineRecoveryExit(t *testing.T) {
	if os.Getenv("PC_CONTROL_DEADLINE_CHILD") == "1" {
		stop := nativeDeadline()
		defer stop()
		time.Sleep(20 * time.Second)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestNativeDeadlineRecoveryExit$")
	cmd.Env = append(os.Environ(), "PC_CONTROL_DEADLINE_CHILD=1")
	out, e := cmd.CombinedOutput()
	var exit *exec.ExitError
	if !errors.As(e, &exit) || exit.ExitCode() != 1 || !strings.Contains(string(out), "exiting for automatic recovery") {
		t.Fatalf("Native watchdog failed: %v %s", e, out)
	}
}
func TestNativeDeadlineCancellation(t *testing.T) {
	synctest.Test(t, func(t *testing.T) { stop := nativeDeadline(); stop(); time.Sleep(9 * time.Second) })
}
