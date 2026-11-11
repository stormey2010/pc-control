package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"golang.org/x/sys/windows"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"
	"unsafe"
)

type pairRequest struct {
	ID, Code, Host string
	Expires        time.Time
	Attempts       int
}

func (s *server) pairStart(w http.ResponseWriter, r *http.Request) {
	s.pairingMu.Lock()
	defer s.pairingMu.Unlock()
	if time.Since(s.pairingLast) < 30*time.Second {
		http.Error(w, "A code was just shown on your PC. Wait 30 seconds before requesting another.", 429)
		return
	}
	n, err := rand.Int(rand.Reader, big.NewInt(10000))
	if err != nil {
		http.Error(w, "Cannot generate code", 500)
		return
	}
	nonce := make([]byte, 16)
	if _, err = rand.Read(nonce); err != nil {
		http.Error(w, "Cannot generate request", 500)
		return
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	req := &pairRequest{ID: hex.EncodeToString(nonce), Code: fmtCode(n.Int64()), Host: host, Expires: time.Now().Add(2 * time.Minute)}
	s.pairingRequest = req
	s.pairingLast = time.Now()
	go showPairCode(req.Code)
	writeJSON(w, 200, map[string]any{"requestId": req.ID, "expiresIn": 120, "deviceId": s.cfg.DeviceID})
}
func fmtCode(n int64) string {
	b := []byte("0000")
	for i := 3; i >= 0; i-- {
		b[i] = byte(n%10) + '0'
		n /= 10
	}
	return string(b)
}
func showPairCode(code string) {
	title, _ := windows.UTF16PtrFromString("PC Control — Pair your iPhone")
	message, _ := windows.UTF16PtrFromString("Enter this code on your iPhone:\n\n                   " + code + "\n\nThis code expires in 2 minutes.\nIf you did not request this, ignore this window.")
	user32.NewProc("MessageBoxTimeoutW").Call(0, uintptr(unsafe.Pointer(message)), uintptr(unsafe.Pointer(title)), 0x50040, 0, 120000)
}
func (s *server) pairConfirm(w http.ResponseWriter, r *http.Request) {
	var body struct {
		RequestID string `json:"requestId"`
		Code      string `json:"code"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body); err != nil {
		http.Error(w, "Invalid pairing request", 400)
		return
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	s.pairingMu.Lock()
	defer s.pairingMu.Unlock()
	p := s.pairingRequest
	if p == nil || p.Host != host || p.ID != body.RequestID || time.Now().After(p.Expires) || p.Attempts >= 5 {
		http.Error(w, "Code expired. Request a new code from your PC.", 403)
		return
	}
	p.Attempts++
	if len(body.Code) != 4 || subtle.ConstantTimeCompare([]byte(p.Code), []byte(body.Code)) != 1 {
		http.Error(w, "Incorrect code. Check the code shown on your PC.", 403)
		return
	}
	b, err := os.ReadFile(filepath.Join(s.dataDir, "connection.json"))
	if err != nil {
		http.Error(w, "PC pairing unavailable", 500)
		return
	}
	s.pairingRequest = nil
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(b)
}
