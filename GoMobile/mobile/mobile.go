// Package mobile wraps go2rtc so it can run inside the Waiting Paws apps (gomobile bind).
//
// It mirrors go2rtc's main() with the modules the apps need: HTTP API + WebSocket player,
// streams registry, RTSP/HTTP sources, WebRTC, MP4/HLS/MJPEG outputs and the Xiaomi source.
package mobile

import (
	"fmt"
	"os"
	"runtime"
	"sync"
	"time"

	"github.com/AlexxIT/go2rtc/internal/api"
	"github.com/AlexxIT/go2rtc/internal/api/ws"
	"github.com/AlexxIT/go2rtc/internal/app"
	"github.com/AlexxIT/go2rtc/internal/hls"
	"github.com/AlexxIT/go2rtc/internal/http"
	"github.com/AlexxIT/go2rtc/internal/mjpeg"
	"github.com/AlexxIT/go2rtc/internal/mp4"
	"github.com/AlexxIT/go2rtc/internal/rtsp"
	"github.com/AlexxIT/go2rtc/internal/streams"
	"github.com/AlexxIT/go2rtc/internal/webrtc"
	"github.com/AlexxIT/go2rtc/internal/xiaomi"
	"github.com/AlexxIT/go2rtc/pkg/xiaomi/miss/cs2"
)

var (
	once     sync.Once
	startErr error
	started  bool
)

// Start boots go2rtc in-process using the given YAML config file (created by the app).
// overrides is an optional inline YAML/JSON config applied on top of the file (go2rtc merges
// configs in order), used by the app to pin listen addresses on every launch while the file
// keeps persistent state (Xiaomi tokens, streams).
// go2rtc keeps global state and parses flags once, so only the first call does anything;
// later calls return the result of the first one.
func Start(configPath string, overrides string) error {
	once.Do(func() {
		defer func() {
			if r := recover(); r != nil {
				startErr = fmt.Errorf("go2rtc failed to start: %v", r)
			}
		}()

		// A phone shares its cores with the UI and WebKit: cap the Go scheduler.
		runtime.GOMAXPROCS(2)

		os.Args = []string{"go2rtc", "-config", configPath}
		if overrides != "" {
			os.Args = append(os.Args, "-config", overrides)
		}
		app.Version = "1.9.14"

		app.Init()           // config and logger
		api.Init()           // HTTP API (serves in a goroutine)
		ws.Init()            // WebSocket endpoint used by video-rtc.js
		streams.Init()       // streams registry
		http.Init()          // http/https sources
		rtsp.Init()          // rtsp sources (server disabled in config)
		webrtc.Init()        // WebRTC output for the player
		mp4.Init()           // MP4 output (recording)
		hls.Init()           // HLS output
		mjpeg.Init()         // MJPEG fallback
		xiaomi.Init()        // Mi Home cameras + /api/xiaomi login
		xiaomi.InitMiot()    // /api/xiaomi/miot: camera settings via Mi Cloud (Waiting Paws addition)
		xiaomi.InitLogout()  // /api/xiaomi/logout: forget a Mi Home account (Waiting Paws addition)
		xiaomi.InitCameras() // /api/xiaomi/cameras: cameras of own and shared homes (Waiting Paws addition)
		xiaomi.InitMotor()   // /api/xiaomi/motor: turn a pan/tilt camera (Waiting Paws addition)

		started = true
	})
	return startErr
}

// IsRunning reports whether Start completed successfully.
func IsRunning() bool {
	return started && startErr == nil
}

// Relisten opens the HTTP API on address again (e.g. "127.0.0.1:11984"). iOS closes the listening
// sockets of a suspended app; the app calls this when it is back and the API no longer answers.
func Relisten(address string) error {
	return api.Relisten(address)
}

// SetLANPassword changes the Basic-auth credentials LAN clients must send, without a restart.
func SetLANPassword(username, password string) {
	api.SetCredentials(username, password)
}

// Version returns the embedded go2rtc version.
func Version() string {
	return app.Version
}

// CloseCameraSessions tells every camera with an open Xiaomi CS2 session that it is over and returns how many there
// were. The app calls it when it quits: a camera serves one session at a time, and one left open by a process that is
// gone made the next launch's connection wait (connected, then no video for 15 s or "can't send command").
func CloseCameraSessions() int {
	return cs2.CloseAll()
}

// SetTimeZone gives Go the device's time zone for log lines: on iOS Go cannot read it and wrote UTC, next to the
// app's own lines in local time. Called before Start.
func SetTimeZone(name string, offsetSeconds int) {
	if location, err := time.LoadLocation(name); err == nil {
		time.Local = location
	} else {
		time.Local = time.FixedZone(name, offsetSeconds) // no zone database on iOS: today's offset is enough for a log
	}
}
