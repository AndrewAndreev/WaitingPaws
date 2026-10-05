package cs2

// Run after ./GoMobile/build.sh: cd GoMobile/build/go2rtc && go test ./pkg/xiaomi/miss/cs2

import (
	"encoding/binary"
	"testing"
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
