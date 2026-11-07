package xiaomi

// Waiting Paws addition, copied into go2rtc's internal/xiaomi by GoMobile/build.sh, which also points the xiaomi
// source's dial at getCameraURLLogged instead of getCameraURL.

import (
	"fmt"
	"net/url"
	"os"
	"time"
)

// getCameraURLLogged is getCameraURL with its time in the log. A camera's session keys come from Mi Cloud before
// every connect (and before every reconnect), so a slow or failing cloud is part of the wait for the picture; without
// this line the log shows only the camera's part ("cs2: connected … in N ms").
func getCameraURLLogged(u *url.URL) (string, error) {
	started := time.Now()
	rawURL, err := getCameraURL(u)
	ms := time.Since(started).Milliseconds()
	if err != nil {
		keysLogf("xiaomi: keys for %s from Mi Cloud failed after %d ms: %v", u.Hostname(), ms, err)
	} else {
		keysLogf("xiaomi: keys for %s from Mi Cloud in %d ms", u.Hostname(), ms)
	}
	return rawURL, err
}

// keysLogf writes a line the way the CS2 transport does (GoMobile/xiaomi-cs2/conn.go), so they read together.
func keysLogf(format string, args ...any) {
	_, _ = fmt.Fprintf(os.Stderr, "%s "+format+"\n", append([]any{time.Now().Format("15:04:05")}, args...)...)
}
