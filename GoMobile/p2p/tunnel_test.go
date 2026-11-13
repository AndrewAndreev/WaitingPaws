package p2p

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"
)

// connectedPair: an offering and an answering link on loopback, connected, the answerer offering `services`.
func connectedPair(t *testing.T, services map[string]string) (*Link, *events, *Link, *events) {
	t.Helper()
	opts := Options{Label: "out", PingInterval: 0.2, Interfaces: []string{"lo"}, Loopback: true}
	answer := opts
	answer.Services = services
	o, oe, a, ae := pair(t, opts, answer)
	if err := o.Start(); err != nil {
		t.Fatal(err)
	}
	oe.waitFor(t, "connection", 20*time.Second, func(s Status) bool { return s.State == "connected" && s.Pongs > 0 })
	return o, oe, a, ae
}

func payload(n int) []byte {
	data := make([]byte, n)
	rand.New(rand.NewSource(int64(n))).Read(data)
	return data
}

// The camera's picture and the sync link over the link: HTTP responses arrive whole (also one the server ends by
// closing), several at once, and a stream carries both ways.
func TestStreamsCarryHTTPAndEcho(t *testing.T) {
	big := payload(6 << 20)
	web := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/close" {
			w.Header().Set("Connection", "close")
		}
		size, _ := strconv.Atoi(r.URL.Query().Get("n"))
		w.Header().Set("Content-Length", strconv.Itoa(size))
		_, _ = w.Write(big[:size])
	}))
	defer web.Close()
	echo, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			conn, err := echo.Accept()
			if err != nil {
				return
			}
			go func() { _, _ = io.Copy(conn, conn); _ = conn.Close() }()
		}
	}()

	o, oe, _, ae := connectedPair(t, map[string]string{"web": web.Listener.Addr().String(), "echo": echo.Addr().String()})
	webPort, err := o.Forward("web", 0)
	if err != nil {
		t.Fatal(err)
	}
	echoPort, err := o.Forward("echo", 0)
	if err != nil {
		t.Fatal(err)
	}

	get := func(path string, n int) error {
		resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d%s?n=%d", webPort, path, n))
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return err
		}
		if sha256.Sum256(body) != sha256.Sum256(big[:n]) {
			return fmt.Errorf("%s: %d bytes, not the %d sent", path, len(body), n)
		}
		return nil
	}
	start := time.Now()
	if err := get("/close", len(big)); err != nil {
		t.Fatal(err)
	}
	t.Logf("6 MB through the link in %v", time.Since(start))

	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs <- get("/", 100_000*(i+1))
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}

	conn, err := net.Dial("tcp4", "127.0.0.1:"+strconv.Itoa(echoPort))
	if err != nil {
		t.Fatal(err)
	}
	sent := payload(1 << 20)
	go func() { _, _ = conn.Write(sent) }()
	back := make([]byte, len(sent))
	_ = conn.SetReadDeadline(time.Now().Add(20 * time.Second))
	if _, err := io.ReadFull(conn, back); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(back, sent) {
		t.Fatal("the echo came back different")
	}
	_ = conn.Close()
	http.DefaultClient.CloseIdleConnections() // its kept-alive connections are streams too

	got := oe.waitFor(t, "stream counters", 5*time.Second, func(s Status) bool { return s.Streams == 0 && s.StreamsOpened >= 3 })
	if got.BytesIn < int64(len(big)) || got.BytesOut < int64(len(sent)) {
		t.Fatalf("counters: in %d, out %d", got.BytesIn, got.BytesOut)
	}
	ae.waitFor(t, "answerer's counters", 5*time.Second, func(s Status) bool { return s.BytesOut >= int64(len(big)) })
}

// Only the services the answerer named are reachable; a connection while the link is down closes at once.
func TestStreamsOnlyToNamedServicesAndWhileUp(t *testing.T) {
	opts := Options{Label: "out", PingInterval: 0.2, Interfaces: []string{"lo"}, Loopback: true}
	o, _, _, _ := pair(t, opts, opts)
	port, err := o.Forward("sync", 0)
	if err != nil {
		t.Fatal(err)
	}
	closedSoon := func(what string) {
		t.Helper()
		conn, err := net.Dial("tcp4", "127.0.0.1:"+strconv.Itoa(port))
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
		if _, err := conn.Read(make([]byte, 1)); err != io.EOF {
			t.Fatalf("%s: read gave %v, not EOF", what, err)
		}
	}
	closedSoon("before the link is up")

	if err := o.Start(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(2 * time.Second)
	closedSoon("a service the answerer does not offer")

	if _, err := o.Forward("a/b", 0); err == nil {
		t.Fatal("a service name with a slash was taken")
	}
	o.Close()
	if conn, err := net.Dial("tcp4", "127.0.0.1:"+strconv.Itoa(port)); err == nil {
		_ = conn.Close()
		t.Fatal("the forwarded port outlived the link")
	}
}
