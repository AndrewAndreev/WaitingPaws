package xiaomi

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/AlexxIT/go2rtc/internal/streams"
	"github.com/AlexxIT/go2rtc/pkg/core"
)

// Run in GoMobile/build/go2rtc after ./GoMobile/build.sh: go test ./internal/xiaomi -run Miot

func miotRequest(form url.Values) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "/api/xiaomi/miot", strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()
	apiMiot(w, r)
	return w
}

func TestMiotOnlyReachesConfiguredCameras(t *testing.T) {
	if !streams.HasProducer("xiaomi://") {
		streams.HandleFunc("xiaomi", func(string) (core.Producer, error) { return nil, errors.New("not in tests") })
	}
	if _, err := streams.New("miot-test-hall", "xiaomi://1001:cn@192.168.1.9?did=555&model=chuangmi.camera.v1"); err != nil {
		t.Fatal(err)
	}

	set := func(src, params string) int {
		return miotRequest(url.Values{"src": {src}, "method": {"set"}, "params": {params}}).Code
	}
	// A plug of the same account, and the camera's did under another account: refused before any cloud call.
	if code := set("xiaomi://1001:cn@x?did=777", `[{"siid":2,"piid":1,"value":true}]`); code != http.StatusForbidden {
		t.Errorf("other device: %d", code)
	}
	if code := set("xiaomi://2002:cn@x?did=555", `[{"siid":2,"piid":1,"value":true}]`); code != http.StatusForbidden {
		t.Errorf("other account: %d", code)
	}
	// The configured camera gets past the check; a null item is a bad request, not a panic.
	if code := set("xiaomi://1001:cn@192.168.1.9?did=555&model=chuangmi.camera.v1", `[null]`); code != http.StatusBadRequest {
		t.Errorf("null item: %d", code)
	}
}
