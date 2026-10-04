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

		app.Init()     // config and logger
		api.Init()     // HTTP API (serves in a goroutine)
		ws.Init()      // WebSocket endpoint used by video-rtc.js
		streams.Init() // streams registry
		http.Init()    // http/https sources
		rtsp.Init()    // rtsp sources (server disabled in config)
		webrtc.Init()  // WebRTC output for the player
		mp4.Init()     // MP4 output (recording)
		hls.Init()     // HLS output
		mjpeg.Init()   // MJPEG fallback
		xiaomi.Init()  // Mi Home cameras + /api/xiaomi login

		started = true
	})
	return startErr
}

// IsRunning reports whether Start completed successfully.
func IsRunning() bool {
	return started && startErr == nil
}

// Version returns the embedded go2rtc version.
func Version() string {
	return app.Version
}
