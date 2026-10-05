// Command desktop is go2rtc for the Waiting Paws desktop app (Electron, Windows): the Electron main process
// spawns it as a child process (Desktop/scripts/build-go2rtc.mjs copies this directory into go2rtc's tree
// as desktop/ and builds resources/bin/go2rtc.exe).
//
// It mirrors GoMobile/mobile (Start) as a normal executable: the same modules, including the Waiting Paws
// Xiaomi additions, and the configs on the command line exactly as go2rtc's own main takes them:
//
//	go2rtc.exe -config <file> -config <inline JSON> [-parent-pid <pid>]
//
// The file keeps persistent state (Xiaomi tokens, streams), the inline config pins the listen addresses on
// every launch (go2rtc merges configs in order). Unlike the phone build there is no GOMAXPROCS cap.
//
// -parent-pid ties the process to its parent: when that process is gone (closed, crashed or killed from Task
// Manager), go2rtc exits by itself instead of holding the ports with nobody to stop it. Stdin is ignored, so
// the parent may spawn it with any stdio; logs go to stdout (go2rtc's logger) and stderr (Xiaomi CS2 stats).
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
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
	"github.com/AlexxIT/go2rtc/pkg/shell"
)

func main() {
	// go2rtc's app.Init parses os.Args with its own flag set and stops at a flag it doesn't know,
	// so -parent-pid is taken out before that.
	args, parentPID, err := takeParentPID(os.Args)
	if err != nil {
		fmt.Fprintln(os.Stderr, "go2rtc:", err)
		os.Exit(2)
	}
	os.Args = args
	if parentPID != 0 {
		if err := exitWithParent(parentPID); err != nil {
			fmt.Fprintln(os.Stderr, "go2rtc:", err)
			os.Exit(1)
		}
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

	// Ctrl+C in a console; the app itself stops it with TerminateProcess (child.kill) or by exiting.
	shell.RunUntilSignal()
}

// takeParentPID removes "-parent-pid N" ("--parent-pid N", "-parent-pid=N") from args and returns N (0 without it).
// Flag parsing ends at "--", like Go's flag package.
func takeParentPID(args []string) (rest []string, pid int, err error) {
	rest = make([]string, 0, len(args))
	rest = append(rest, args[0])
	for i := 1; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			rest = append(rest, args[i:]...)
			break
		}
		name, value, hasValue := strings.Cut(strings.TrimPrefix(strings.TrimPrefix(arg, "-"), "-"), "=")
		if !strings.HasPrefix(arg, "-") || name != "parent-pid" {
			rest = append(rest, arg)
			continue
		}
		if !hasValue {
			if i+1 == len(args) {
				return nil, 0, fmt.Errorf("-parent-pid needs a process id")
			}
			i++
			value = args[i]
		}
		if pid, err = strconv.Atoi(value); err != nil || pid <= 0 {
			return nil, 0, fmt.Errorf("-parent-pid: bad process id %q", value)
		}
	}
	return rest, pid, nil
}

// parentGone is called once the parent process has exited.
func parentGone(pid int) {
	fmt.Fprintf(os.Stderr, "%s INF [desktop] parent process %d is gone, exiting\n", time.Now().Format("15:04:05.000"), pid)
	os.Exit(0)
}
