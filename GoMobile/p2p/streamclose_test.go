package p2p

import (
	"io"
	"net"
	"strconv"
	"testing"
	"time"
)

// A stream's TCP connection ends when its link is closed on this side (a knock replaces the link), and when the
// peer's link goes away without a word (the Mac quit).
func TestStreamsEndWithTheirLink(t *testing.T) {
	for _, peerDies := range []bool{false, true} {
		echo, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		go func() {
			for {
				conn, err := echo.Accept()
				if err != nil {
					return
				}
				go func() { _, _ = io.Copy(conn, conn) }()
			}
		}()
		o, _, a, _ := connectedPair(t, map[string]string{"echo": echo.Addr().String()})
		port, err := o.Forward("echo", 0)
		if err != nil {
			t.Fatal(err)
		}
		conn, err := net.Dial("tcp4", "127.0.0.1:"+strconv.Itoa(port))
		if err != nil {
			t.Fatal(err)
		}
		_, _ = conn.Write([]byte("hi"))
		buf := make([]byte, 2)
		_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		if _, err := io.ReadFull(conn, buf); err != nil {
			t.Fatal(err)
		}
		start := time.Now()
		if peerDies {
			a.mu.Lock()
			pc := a.cur.pc
			a.mu.Unlock()
			_ = pc.Close() // no bye, as when the Mac app quits
		} else {
			o.Close()
		}
		_ = conn.SetReadDeadline(time.Now().Add(30 * time.Second))
		_, err = conn.Read(buf)
		t.Logf("peerDies=%v: read after %v: %v", peerDies, time.Since(start).Round(time.Millisecond), err)
		_ = conn.Close()
		_ = echo.Close()
		o.Close()
		a.Close()
	}
}
