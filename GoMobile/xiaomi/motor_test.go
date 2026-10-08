package xiaomi

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/AlexxIT/go2rtc/internal/streams"
	"github.com/AlexxIT/go2rtc/pkg/core"
)

// Run in GoMobile/build/go2rtc after ./GoMobile/build.sh: go test ./internal/xiaomi -run Motor

type fakeCamera struct {
	core.Producer // never called
	operations    []int
	err           error
}

func (f *fakeCamera) Motor(operation int) error {
	f.operations = append(f.operations, operation)
	return f.err
}

type fixedCamera struct{ core.Producer }

func motorRequest(query string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	apiMotor(w, httptest.NewRequest("POST", "/api/xiaomi/motor?"+query, nil))
	return w
}

func TestMotorStepsTheRunningCamera(t *testing.T) {
	camera := &fakeCamera{}
	stream, _ := streams.New("motor-test-hall")
	stream.AddProducer(&fixedCamera{})
	stream.AddProducer(camera)

	if w := motorRequest("src=motor-test-hall&operation=2"); w.Code != http.StatusNoContent {
		t.Fatalf("status %d: %s", w.Code, w.Body)
	}
	if w := motorRequest("src=motor-test-hall&operation=3"); w.Code != http.StatusNoContent {
		t.Fatalf("status %d: %s", w.Code, w.Body)
	}
	if len(camera.operations) != 2 || camera.operations[0] != 2 || camera.operations[1] != 3 {
		t.Fatalf("operations %v", camera.operations)
	}

	camera.err = errors.New("cs2: can't send command")
	if w := motorRequest("src=motor-test-hall&operation=1"); w.Code != http.StatusBadGateway {
		t.Fatalf("a failed step: status %d", w.Code)
	}
}

func TestMotorRefusesBadRequests(t *testing.T) {
	stream, _ := streams.New("motor-test-fixed")
	stream.AddProducer(&fixedCamera{})

	for query, status := range map[string]int{
		"src=motor-test-fixed&operation=0":   http.StatusBadRequest,
		"src=motor-test-fixed&operation=5":   http.StatusBadRequest,
		"src=motor-test-fixed&operation=up":  http.StatusBadRequest,
		"src=motor-test-nowhere&operation=1": http.StatusConflict,
		"src=motor-test-fixed&operation=1":   http.StatusConflict, // its source has no motor
	} {
		if w := motorRequest(query); w.Code != status {
			t.Errorf("%s: status %d, want %d", query, w.Code, status)
		}
	}

	w := httptest.NewRecorder()
	apiMotor(w, httptest.NewRequest("GET", "/api/xiaomi/motor?src=motor-test-fixed&operation=1", nil))
	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET: status %d", w.Code)
	}
}
