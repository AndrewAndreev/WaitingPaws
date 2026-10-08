package xiaomi

// Waiting Paws addition, copied into go2rtc's internal/xiaomi by GoMobile/build.sh.
//
// Turning a pan/tilt camera from the app. The step itself is GoMobile/xiaomi-miss/motor.go; it rides on the camera
// session of a running stream, so it only works while someone watches or records that stream (the app turns the
// camera from its live view). The request has the shape of upstream PR AlexxIT/go2rtc#2531, so the app would also
// turn the camera through a go2rtc that ships it.

import (
	"net/http"
	"strconv"

	"github.com/AlexxIT/go2rtc/internal/api"
	"github.com/AlexxIT/go2rtc/internal/streams"
)

// InitMotor registers POST /api/xiaomi/motor?src=<stream name>&operation=<1 left|2 right|3 up|4 down>.
//
// 204: the step was sent (the picture follows about a second later). 400: bad operation. 409: no such stream, the
// stream is not running, or its source can't turn (not a Mi Home camera of the MISS kind). 502: the camera
// connection failed to take the command.
func InitMotor() {
	api.HandleFunc("api/xiaomi/motor", apiMotor)
}

type motorSource interface {
	Motor(operation int) error
}

func apiMotor(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	operation, err := strconv.Atoi(r.FormValue("operation"))
	if err != nil || operation < 1 || operation > 4 {
		http.Error(w, "operation must be 1 (left), 2 (right), 3 (up) or 4 (down)", http.StatusBadRequest)
		return
	}
	name := r.FormValue("src")
	stream := streams.Get(name)
	if stream == nil {
		http.Error(w, "no stream "+strconv.Quote(name), http.StatusConflict)
		return
	}
	for _, conn := range stream.Conns() {
		if source, ok := conn.(motorSource); ok {
			if err = source.Motor(operation); err != nil {
				http.Error(w, err.Error(), http.StatusBadGateway)
				return
			}
			w.WriteHeader(http.StatusNoContent)
			return
		}
	}
	http.Error(w, "stream "+strconv.Quote(name)+" is not running or its camera can't turn", http.StatusConflict)
}
