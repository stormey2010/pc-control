package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/grandcat/zeroconf"
	"golang.org/x/sys/windows"
)

const version = "1.0.0"

type Config struct {
	Port     int    `json:"port"`
	Token    string `json:"token"`
	DeviceID string `json:"deviceId"`
	Name     string `json:"name"`
}
type Connection struct {
	Version           string   `json:"version"`
	DeviceID          string   `json:"deviceId"`
	Name              string   `json:"name"`
	Port              int      `json:"port"`
	URLs              []string `json:"urls"`
	Token             string   `json:"token"`
	CertificateSHA256 string   `json:"certificateSha256"`
	Discovery         string   `json:"discovery"`
}

func main() {
	dir := flag.String("data-dir", filepath.Join(os.Getenv("LOCALAPPDATA"), "PCControl"), "Private installation directory")
	supervise := flag.Bool("supervise", false, "Supervise the background worker")
	setup := flag.Bool("setup", false, "Create credentials and certificate without starting")
	flag.Parse()
	if err := os.MkdirAll(*dir, 0700); err != nil {
		return
	}
	// Bound logging: keep the previous 1 MiB file, never record commands or secrets.
	logPath := filepath.Join(*dir, "agent.log")
	if *supervise {
		logPath = filepath.Join(*dir, "supervisor.log")
	}
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	w := &rotatingLog{f: f, path: logPath, max: 1 << 20}
	defer w.Close()
	log.SetOutput(w)
	if err := run(*dir, *supervise, *setup); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
func run(dir string, supervise, setup bool) error {
	if supervise {
		return supervisor(dir)
	}
	// Keep coordinates in physical pixels across displays with different scaling.
	_, _, _ = user32.NewProc("SetProcessDpiAwarenessContext").Call(^uintptr(3))
	mutexName, _ := windows.UTF16PtrFromString("Local\\PCControl.Agent." + strings.ReplaceAll(dir, "\\", "_"))
	m, err := windows.CreateMutex(nil, false, mutexName)
	if err != nil {
		if m != 0 {
			windows.CloseHandle(m)
		}
		return err
	}
	defer windows.CloseHandle(m)
	cfg, cert, err := loadConfig(dir)
	if err != nil {
		return err
	}
	if setup {
		return nil
	}
	recoverHeldInput(dir)
	api := newServer(cfg)
	api.dataDir = dir
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", api.health)
	mux.HandleFunc("POST /v1/pair/start", api.pairStart)
	mux.HandleFunc("POST /v1/pair/confirm", api.pairConfirm)
	mux.HandleFunc("GET /v1/info", api.auth(api.info))
	mux.HandleFunc("GET /v1/diagnostics", api.auth(api.diagnostics))
	mux.HandleFunc("POST /v1/command", api.auth(api.command))
	mux.HandleFunc("GET /v1/ws", api.auth(api.websocket))
	srv := &http.Server{Addr: fmt.Sprintf(":%d", cfg.Port), Handler: api.localOnly(mux), TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}}, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 8192, ErrorLog: log.New(fixedLogWriter{}, "", 0)}
	// Discovery exposes the public certificate fingerprint, never credentials.
	fingerprint := sha256.Sum256(cert.Certificate[0])
	z, err := zeroconf.Register(cfg.Name+"-"+cfg.DeviceID[:8], "_pccontrol._tcp", "local.", cfg.Port, []string{"version=1", "id=" + cfg.DeviceID, "tls=1", "path=/v1/ws", "pin=" + hex.EncodeToString(fingerprint[:])}, nil)
	if err == nil {
		defer z.Shutdown()
	} else {
		log.Print("mDNS unavailable; direct IP remains available")
	}
	log.Printf("PC Control %s ready on TLS port %d", version, cfg.Port)
	return srv.ListenAndServeTLS("", "")
}

type fixedLogWriter struct{}

func (fixedLogWriter) Write(b []byte) (int, error) { return len(b), nil } // suppress peer-supplied TLS log spam
type rotatingLog struct {
	mu   sync.Mutex
	f    *os.File
	path string
	max  int64
}

func (w *rotatingLog) Close() error { w.mu.Lock(); defer w.mu.Unlock(); return w.f.Close() }
func (w *rotatingLog) Write(b []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	st, e := w.f.Stat()
	if e != nil {
		return 0, e
	}
	if st.Size()+int64(len(b)) > w.max {
		_ = w.f.Close()
		_ = os.Remove(w.path + ".old")
		if e = os.Rename(w.path, w.path+".old"); e != nil {
			return 0, e
		}
		w.f, e = os.OpenFile(w.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		if e != nil {
			return 0, e
		}
	}
	return w.f.Write(b)
}
func supervisor(dir string) error {
	name, _ := windows.UTF16PtrFromString("Local\\PCControl.Supervisor." + strings.ReplaceAll(dir, "\\", "_"))
	m, err := windows.CreateMutex(nil, false, name)
	if err != nil {
		if m != 0 {
			windows.CloseHandle(m)
		}
		return err
	}
	defer windows.CloseHandle(m)
	// A supervisor crash must also terminate its worker, so Task Scheduler can
	// restart the complete tree without leaving an orphan holding the API port.
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(job)
	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		return err
	}
	if err = windows.AssignProcessToJobObject(job, windows.CurrentProcess()); err != nil {
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	delay := time.Second
	for {
		start := time.Now()
		cmd := exec.Command(exe, "--data-dir", dir)
		cmd.SysProcAttr = hiddenProcess()
		err = cmd.Run()
		recoverHeldInput(dir)
		log.Printf("Worker stopped; restarting in %s (error=%v)", delay, err)
		time.Sleep(delay)
		if time.Since(start) > time.Minute {
			delay = time.Second
		} else if delay < 30*time.Second {
			delay = min(delay*2, 30*time.Second)
		}
	}
}
func loadConfig(dir string) (Config, tls.Certificate, error) {
	var cfg Config
	path := filepath.Join(dir, "config.json")
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		t := make([]byte, 32)
		if _, err = rand.Read(t); err != nil {
			return cfg, tls.Certificate{}, err
		}
		id := make([]byte, 16)
		if _, err = rand.Read(id); err != nil {
			return cfg, tls.Certificate{}, err
		}
		name, _ := os.Hostname()
		cfg = Config{48180, base64.RawURLEncoding.EncodeToString(t), hex.EncodeToString(id), name}
		b, _ = json.MarshalIndent(cfg, "", "  ")
		err = os.WriteFile(path, b, 0600)
	} else if err == nil {
		err = json.Unmarshal(b, &cfg)
	}
	if err != nil {
		return cfg, tls.Certificate{}, err
	}
	if cfg.Port < 1024 || cfg.Port > 65535 || len(cfg.Token) < 32 || len(cfg.DeviceID) < 8 {
		return cfg, tls.Certificate{}, fmt.Errorf("invalid config")
	}
	certPath, keyPath := filepath.Join(dir, "server.pem"), filepath.Join(dir, "server.key")
	if _, err = os.Stat(certPath); errors.Is(err, os.ErrNotExist) {
		key, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if e != nil {
			return cfg, tls.Certificate{}, e
		}
		serial, e := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
		if e != nil {
			return cfg, tls.Certificate{}, e
		}
		tpl := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "PC Control " + cfg.DeviceID}, NotBefore: time.Now().Add(-24 * time.Hour), NotAfter: time.Now().AddDate(10, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, DNSNames: []string{cfg.Name, cfg.Name + ".local", "localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}}
		for _, ip := range localIPs() {
			tpl.IPAddresses = append(tpl.IPAddresses, net.ParseIP(ip))
		}
		der, e := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
		if e != nil {
			return cfg, tls.Certificate{}, e
		}
		kb, e := x509.MarshalPKCS8PrivateKey(key)
		if e != nil {
			return cfg, tls.Certificate{}, e
		}
		if e = os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: kb}), 0600); e != nil {
			return cfg, tls.Certificate{}, e
		}
		if e = os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); e != nil {
			return cfg, tls.Certificate{}, e
		}
	}
	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return cfg, cert, err
	}
	sum := sha256.Sum256(cert.Certificate[0])
	urls := []string{"https://127.0.0.1:" + fmt.Sprint(cfg.Port)}
	for _, ip := range localIPs() {
		urls = append(urls, fmt.Sprintf("https://%s:%d", ip, cfg.Port))
	}
	connection := Connection{version, cfg.DeviceID, cfg.Name, cfg.Port, urls, cfg.Token, hex.EncodeToString(sum[:]), "_pccontrol._tcp"}
	b, _ = json.MarshalIndent(connection, "", "  ")
	err = os.WriteFile(filepath.Join(dir, "connection.json"), b, 0600)
	return cfg, cert, err
}
func localIPs() []string {
	var ips []string
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		ip, _, err := net.ParseCIDR(a.String())
		if err == nil && ip.To4() != nil && ip.IsPrivate() {
			ips = append(ips, ip.String())
		}
	}
	return ips
}
