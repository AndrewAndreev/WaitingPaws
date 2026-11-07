package cs2

// Run after ./GoMobile/build.sh: cd GoMobile/build/go2rtc && go test ./pkg/xiaomi/miss/cs2

import (
	"encoding/binary"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

// message frames one media message the way the camera does: a 4-byte size, then the bytes.
func message(b byte, size int) []byte {
	out := make([]byte, 4+size)
	binary.BigEndian.PutUint32(out, uint32(size))
	for i := range size {
		out[4+i] = b
	}
	return out
}

func TestReorderBufferWaitsForTheMissingPacketAndCounts(t *testing.T) {
	c := newDataChannel(2048, 1000)
	// Packet 1 is lost: 2 and 3 arrive first and are kept (and acknowledged).
	for _, seq := range []uint16{0, 2, 3} {
		if pushed, err := c.PushSeq(seq, message(byte(seq), 10)); err != nil || pushed < 0 {
			t.Fatalf("seq %d: pushed %d err %v", seq, pushed, err)
		}
	}
	if got := len(c.popBuf); got != 1 {
		t.Fatalf("only seq 0 may be delivered before the gap is filled, got %d", got)
	}
	// The camera resends 1: everything up to 3 goes out in order.
	if pushed, _ := c.PushSeq(1, message(1, 10)); pushed != 3 {
		t.Fatalf("filling the gap should deliver 3 packets, got %d", pushed)
	}
	for want := byte(0); want < 4; want++ {
		data, _ := c.Pop()
		if data[0] != want {
			t.Fatalf("out of order: got %d, want %d", data[0], want)
		}
	}
	// A late duplicate of 2 is ignored but counted.
	_, _ = c.PushSeq(2, message(2, 10))
	s := c.takeStats()
	if s.packets != 5 || s.outOfOrder != 2 || s.duplicates != 1 || s.refused != 0 || s.maxWaiting != 2 {
		t.Fatalf("unexpected stats %+v", s)
	}
}

func TestFullReorderBufferRefusesInsteadOfGrowing(t *testing.T) {
	c := newDataChannel(2, 10)
	_, _ = c.PushSeq(1, message(1, 1))
	_, _ = c.PushSeq(2, message(2, 1))
	if pushed, _ := c.PushSeq(3, message(3, 1)); pushed != -1 {
		t.Fatalf("a full buffer must refuse (no ACK, the camera resends), got %d", pushed)
	}
	if s := c.takeStats(); s.refused != 1 {
		t.Fatalf("refused not counted: %+v", s)
	}
}

// frame is one media message with a miss header: codec at 4–7, capture time (ms) at 16–23, then the payload.
func frame(codec uint32, ts uint64) []byte {
	msg := make([]byte, hdrSize+100)
	binary.LittleEndian.PutUint32(msg[4:], codec)
	binary.LittleEndian.PutUint64(msg[16:], ts)
	out := binary.BigEndian.AppendUint32(nil, uint32(len(msg)))
	return append(out, msg...)
}

func TestTimingTellsHeldUpDeliveryFromMissingFrames(t *testing.T) {
	c := newDataChannel(0, 100)
	c.timing = true
	// Frames 66 ms apart on the camera; the third one is held up for ~150 ms on the way. Audio doesn't count.
	_ = c.Push(frame(5, 1_000))
	_ = c.Push(frame(5, 1_066))
	_ = c.Push(frame(1032, 1_070))
	time.Sleep(150 * time.Millisecond)
	_ = c.Push(frame(5, 1_133))
	s := c.takeStats()
	if s.frames != 3 {
		t.Fatalf("video frames: got %d, want 3", s.frames)
	}
	if s.longestPause < 140*time.Millisecond || s.pauseCameraMs != 67 {
		t.Fatalf("pause %v (camera %d ms): want ~150 ms of 67 ms camera time", s.longestPause, s.pauseCameraMs)
	}
	if spread := s.maxOffset - s.minOffset; spread < 70 || spread > 200 {
		t.Fatalf("delivery spread %d ms: want about 150 − 67", spread)
	}
}

func TestHeldUpWhileAPacketIsMissing(t *testing.T) {
	c := newDataChannel(2048, 1000)
	_, _ = c.PushSeq(0, message(0, 10))
	if held := c.heldUp(); held != 0 {
		t.Fatalf("nothing missing: held %v", held)
	}
	_, _ = c.PushSeq(2, message(2, 10)) // 1 is missing
	time.Sleep(30 * time.Millisecond)
	if held := c.heldUp(); held < 25*time.Millisecond {
		t.Fatalf("waiting for packet 1: held %v", held)
	}
	_, _ = c.PushSeq(1, message(1, 10))
	if held := c.heldUp(); held != 0 {
		t.Fatalf("the gap is filled: held %v", held)
	}
}

func TestStrugglingCameraIsAskedForTCPForAnHour(t *testing.T) {
	if strugglingOverUDP("10.0.0.9") {
		t.Fatal("no trouble yet")
	}
	udpTrouble.Store("10.0.0.9", time.Now())
	if !strugglingOverUDP("10.0.0.9") {
		t.Fatal("just struggled")
	}
	udpTrouble.Store("10.0.0.9", time.Now().Add(-61*time.Minute))
	if strugglingOverUDP("10.0.0.9") {
		t.Fatal("an hour later UDP is tried again")
	}
}

// fakeCamera answers the LAN search and the punch on 127.0.0.1 like a camera offering UDP, and hands over every
// message type it gets along with the client's address.
type fakeCamera struct {
	conn     *net.UDPConn
	received chan byte
	client   chan *net.UDPAddr
}

func newFakeCamera(t *testing.T) *fakeCamera {
	t.Helper()
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	saved := lanPort
	lanPort = conn.LocalAddr().(*net.UDPAddr).Port
	t.Cleanup(func() {
		lanPort = saved
		_ = conn.Close()
	})
	cam := &fakeCamera{conn: conn, received: make(chan byte, 100), client: make(chan *net.UDPAddr, 100)}
	go func() {
		buf := make([]byte, 1500)
		for {
			n, addr, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			if n < 2 {
				continue
			}
			cam.received <- buf[1]
			cam.client <- addr
			reply := make([]byte, 16)
			reply[0] = magic
			switch buf[1] {
			case msgLanSearch:
				reply[1] = msgPunchPkt
			case msgPunchPkt:
				reply[1] = msgP2PRdyUDP
			default:
				continue
			}
			_, _ = conn.WriteToUDP(reply, addr)
		}
	}()
	return cam
}

// next waits for the next message of type want, skipping others.
func (cam *fakeCamera) next(t *testing.T, want byte) *net.UDPAddr {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for {
		select {
		case got := <-cam.received:
			addr := <-cam.client
			if got == want {
				return addr
			}
		case <-deadline:
			t.Fatalf("the camera never got message 0x%02X", want)
		}
	}
}

func TestClosingTellsTheCamera(t *testing.T) {
	cam := newFakeCamera(t)
	c, err := Dial("127.0.0.1", "")
	if err != nil {
		t.Fatal(err)
	}
	if c.isTCP {
		t.Fatal("the camera offered UDP")
	}
	if _, open := sessions.Load(c); !open {
		t.Fatal("an open session is known to CloseAll")
	}
	_ = c.Close()
	cam.next(t, msgClose)
	if _, open := sessions.Load(c); open {
		t.Fatal("a closed session is forgotten")
	}
	select {
	case <-c.done:
	case <-time.After(time.Second):
		t.Fatal("the reader stops when the session is closed")
	}
	if err := c.Close(); err == nil {
		t.Fatal("a second close is an error, and the camera is not told again")
	}
}

func TestCloseAllTellsEveryCamera(t *testing.T) {
	cam := newFakeCamera(t)
	t.Cleanup(func() { quitting.Store(false) })
	for range 2 {
		if _, err := Dial("127.0.0.1", ""); err != nil {
			t.Fatal(err)
		}
	}
	if n := CloseAll(); n != 2 {
		t.Fatalf("closed %d sessions, want 2", n)
	}
	// Each session says goodbye twice (UDP may lose one): at least one from each of the two clients.
	clients := map[string]bool{}
	for len(clients) < 2 {
		clients[cam.next(t, msgClose).String()] = true
	}
	if n := CloseAll(); n != 0 {
		t.Fatalf("closed %d sessions again", n)
	}
}

func TestCameraClosingEndsTheSessionAtOnce(t *testing.T) {
	cam := newFakeCamera(t)
	c, err := Dial("127.0.0.1", "")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	client := cam.next(t, msgPunchPkt)
	_, _ = cam.conn.WriteToUDP([]byte{magic, msgClose, 0, 0}, client)
	select {
	case <-c.done:
	case <-time.After(time.Second):
		t.Fatal("the session goes on after the camera closed it")
	}
	if err := c.Error(); err == nil || !strings.Contains(err.Error(), "the camera closed the session") {
		t.Fatalf("error %v", err)
	}
}

func TestSearchGoesOnWhenSendingFails(t *testing.T) {
	conn, err := net.ListenUDP("udp", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	// Broadcast without SO_BROADCAST: every send fails ("permission denied"), as "no route to host" did at launch.
	c := &udpConn{UDPConn: conn, addr: &net.UDPAddr{IP: net.IPv4bcast, Port: 9}}
	_ = c.SetDeadline(time.Now().Add(2200 * time.Millisecond))
	_, _, err = c.WriteUntil([]byte{magic, msgLanSearch, 0, 0}, func([]byte) bool { return true })
	if err == nil {
		t.Fatal("nobody answers a failed send")
	}
	var sent int
	if _, scanErr := fmt.Sscanf(err.Error()[strings.LastIndex(err.Error(), "(")+1:], "%d sent, all failed", &sent); scanErr != nil {
		t.Fatalf("the timeout says how sending went: %v", err)
	}
	if sent < 2 {
		t.Fatalf("sent %d times in 2.2 s: the search stopped after the failed send (%v)", sent, err)
	}
}

func TestSilentCameraNamesTheStep(t *testing.T) {
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close() // takes datagrams, never answers
	saved := lanPort
	lanPort = conn.LocalAddr().(*net.UDPAddr).Port
	defer func() { lanPort = saved }()
	_, _, err = handshake("127.0.0.1", "")
	if err == nil || !strings.Contains(err.Error(), "no answer to the LAN search") || !strings.Contains(err.Error(), "i/o timeout") {
		t.Fatalf("error %v", err)
	}
}

func TestNoNewSessionOnceQuitting(t *testing.T) {
	cam := newFakeCamera(t)
	t.Cleanup(func() { quitting.Store(false) })
	CloseAll()
	if _, err := Dial("127.0.0.1", ""); err == nil || !strings.Contains(err.Error(), "quitting") {
		t.Fatalf("a quitting app dialled a camera: %v", err)
	}
	select {
	case got := <-cam.received:
		t.Fatalf("the camera got message 0x%02X from a quitting app", got)
	case <-time.After(300 * time.Millisecond):
	}
}

func TestOneAnsweredSearchLeavesTheStepPlain(t *testing.T) {
	newFakeCamera(t)
	conn, steps, err := handshake("127.0.0.1", "")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if strings.Contains(steps, "sent") || !strings.HasPrefix(steps, "search ") || !strings.Contains(steps, ", punch ") {
		t.Fatalf("steps %q", steps)
	}
}
