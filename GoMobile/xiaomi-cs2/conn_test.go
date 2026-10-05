package cs2

// Run after ./GoMobile/build.sh: cd GoMobile/build/go2rtc && go test ./pkg/xiaomi/miss/cs2

import (
	"encoding/binary"
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
