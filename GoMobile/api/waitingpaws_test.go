package api

// Run after ./GoMobile/build.sh: cd GoMobile/build/go2rtc && go test ./internal/api -run WaitingPaws

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestWaitingPawsGuardAndAuth(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	h := middlewareAuth("waitingpaws", "old", false, guard(ok))
	do := func(method, path, remote, user, pass string, header ...string) int {
		r := httptest.NewRequest(method, "http://192.168.1.5:11984"+path, nil)
		r.RemoteAddr = remote
		if user != "" {
			r.SetBasicAuth(user, pass)
		}
		for i := 0; i+1 < len(header); i += 2 {
			if header[i] == "Host" {
				r.Host = header[i+1]
			} else {
				r.Header.Set(header[i], header[i+1])
			}
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}
	lan, local := "192.168.1.20:5000", "127.0.0.1:5000"
	cases := []struct {
		name                     string
		method, path, user, pass string
		remote                   string
		header                   []string
		want                     int
	}{
		{"lan without auth", "GET", "/api", "", "", lan, nil, 401},
		{"lan with auth", "GET", "/api", "waitingpaws", "old", lan, nil, 200},
		{"lan config", "GET", "/api/config", "waitingpaws", "old", lan, nil, 403},
		{"lan xiaomi accounts", "GET", "/api/xiaomi", "waitingpaws", "old", lan, nil, 403},
		{"lan xiaomi logout", "POST", "/api/xiaomi/logout", "waitingpaws", "old", lan, nil, 403},
		{"lan xiaomi cameras", "GET", "/api/xiaomi/cameras", "waitingpaws", "old", lan, nil, 403},
		{"lan camera modes", "POST", "/api/xiaomi/miot", "waitingpaws", "old", lan, nil, 200},
		{"lan stream change", "PUT", "/api/streams", "waitingpaws", "old", lan, nil, 403},
		{"lan streams", "GET", "/api/streams", "waitingpaws", "old", lan, nil, 200},
		{"lan player", "GET", "/api/ws", "waitingpaws", "old", lan, nil, 200},
		{"local config", "GET", "/api/config", "", "", local, nil, 200},
		{"local config write", "POST", "/api/config", "", "", local, nil, 403},
		{"local exit", "POST", "/api/exit", "", "", local, nil, 403},
		{"local restart", "POST", "/api/restart", "", "", local, nil, 403},
		{"local stream change", "PUT", "/api/streams", "", "", local, nil, 200},
		{"web page origin", "GET", "/api/ws", "", "", local, []string{"Origin", "https://evil.example"}, 403},
		{"own player origin", "GET", "/api/ws", "", "", local, []string{"Origin", "http://192.168.1.5:11984"}, 200},
		{"dns rebinding", "GET", "/api", "", "", local, []string{"Host", "rebind.example:11984"}, 403},
		{"bonjour name", "GET", "/api", "", "", local, []string{"Host", "mac.local:11984"}, 200},
	}
	for _, c := range cases {
		if got := do(c.method, c.path, c.remote, c.user, c.pass, c.header...); got != c.want {
			t.Errorf("%s: got %d, want %d", c.name, got, c.want)
		}
	}

	SetCredentials("waitingpaws", "new")
	if got := do("GET", "/api", lan, "waitingpaws", "old"); got != 401 {
		t.Errorf("old password after rotation: got %d", got)
	}
	if got := do("GET", "/api", lan, "waitingpaws", "new"); got != 200 {
		t.Errorf("new password after rotation: got %d", got)
	}
}
