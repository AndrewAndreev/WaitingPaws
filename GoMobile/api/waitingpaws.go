package api

// Waiting Paws addition, copied into go2rtc's internal/api by GoMobile/build.sh.
//
// The embedded go2rtc listens on 127.0.0.1 (and on the LAN on a Mac that shares its camera with an
// iPhone). Upstream go2rtc trusts every loopback request, so a web page open in the Mac's browser could
// talk to it: watch the camera over WebSocket, stop the app with /api/exit or rewrite the config with
// the Xiaomi tokens. The guard below keeps the API to what the app itself uses.

import (
	"crypto/subtle"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"time"
)

var lanCredentials atomic.Pointer[[2]string]

// SetCredentials replaces the Basic-auth user and password checked for LAN clients, without a restart
// (the Mac changes its password when the user forgets a linked iPhone).
func SetCredentials(username, password string) {
	lanCredentials.Store(&[2]string{username, password})
}

// credentialsOK is called by the patched middlewareAuth instead of comparing with the config values.
func credentialsOK(user, pass, cfgUser, cfgPass string) bool {
	if c := lanCredentials.Load(); c != nil {
		cfgUser, cfgPass = c[0], c[1]
	}
	userOK := subtle.ConstantTimeCompare([]byte(user), []byte(cfgUser)) == 1
	passOK := subtle.ConstantTimeCompare([]byte(pass), []byte(cfgPass)) == 1
	return userOK && passOK
}

// guard wraps the API mux (see build.sh):
//   - Host must be an IP address, localhost or a .local name, so DNS rebinding can't reach the API;
//   - a browser Origin must be this server itself: no cross-site requests, WebSocket included;
//   - /api/exit and /api/restart are gone and the config can't be rewritten over HTTP;
//   - LAN clients (a linked iPhone) only watch: no config, log, Xiaomi accounts or stream changes.
func guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !allowedHost(r.Host) {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		if origin := r.Header.Get("Origin"); origin != "" && !sameOrigin(origin, r.Host) {
			http.Error(w, "forbidden origin", http.StatusForbidden)
			return
		}

		path := strings.TrimPrefix(r.URL.Path, basePath)
		switch {
		case path == "/api/exit", path == "/api/restart":
			http.Error(w, "disabled", http.StatusForbidden)
			return
		case path == "/api/config" && r.Method != "GET":
			http.Error(w, "read only", http.StatusForbidden)
			return
		}

		if !isLoopback(r.RemoteAddr) {
			switch {
			case path == "/api/config", path == "/api/log", path == "/api/xiaomi", path == "/api/xiaomi/logout",
				path == "/api/xiaomi/cameras",
				path == "/api/streams" && r.Method != "GET":
				http.Error(w, "local only", http.StatusForbidden)
				return
			}
		}

		next.ServeHTTP(w, r)
	})
}

func allowedHost(hostPort string) bool {
	if hostPort == "" {
		return true
	}
	host := hostPort
	if h, _, err := net.SplitHostPort(hostPort); err == nil {
		host = h
	}
	host = strings.ToLower(strings.Trim(host, "[]"))
	return host == "localhost" || net.ParseIP(host) != nil || strings.HasSuffix(host, ".local")
}

func sameOrigin(origin, host string) bool {
	u, err := url.Parse(origin)
	if err != nil || u.Host == "" {
		return false
	}
	return strings.EqualFold(u.Host, host)
}

// Relisten opens the API listener again. iOS closes the listening sockets of a suspended app; the app
// calls this when it comes back and 127.0.0.1 no longer answers.
func Relisten(address string) error {
	ln, err := net.Listen("tcp", address)
	if err != nil {
		return err
	}
	log.Info().Str("addr", address).Msg("[api] listen again")
	go func() {
		server := http.Server{Handler: Handler, ReadHeaderTimeout: 5 * time.Second}
		if err := server.Serve(ln); err != nil {
			log.Error().Err(err).Msg("[api] serve")
		}
	}()
	return nil
}
