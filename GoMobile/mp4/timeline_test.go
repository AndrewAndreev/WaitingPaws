package mp4

// Run after ./GoMobile/build.sh: cd GoMobile/build/go2rtc && go test ./pkg/mp4

import (
	"testing"

	"github.com/AlexxIT/go2rtc/pkg/core"
	"github.com/AlexxIT/go2rtc/pkg/iso"
	"github.com/pion/rtp"
)

type written struct {
	track, dts, duration uint32
	payload              byte
}

// decode reads back the one sample a fragment from GetPayload carries.
func decode(t *testing.T, fragment []byte) written {
	t.Helper()
	atoms, err := iso.DecodeAtoms(fragment)
	if err != nil {
		t.Fatal(err)
	}
	var w written
	for _, atom := range atoms {
		switch atom := atom.(type) {
		case *iso.AtomTfhd:
			w.track, w.duration = atom.TrackID, atom.SampleDuration
		case *iso.AtomTfdt:
			w.dts = uint32(atom.DecodeTime)
		case *iso.AtomMdat:
			w.payload = atom.Data[len(atom.Data)-1]
		}
	}
	return w
}

func newMuxer(timeline bool, codecs ...*core.Codec) *Muxer {
	m := &Muxer{timeline: timeline}
	for _, codec := range codecs {
		m.AddTrack(codec)
	}
	return m
}

// packet carries `id` in a one-NALU AVCC payload (a non-key H.264 slice; the audio tracks don't look inside).
func packet(ts uint32, id byte) *rtp.Packet {
	return &rtp.Packet{Header: rtp.Header{Timestamp: ts}, Payload: []byte{0, 0, 0, 2, 0x41, id}}
}

var (
	h264Codec = &core.Codec{Name: core.CodecH264, ClockRate: 90000}
	opusCodec = &core.Codec{Name: core.CodecOpus, ClockRate: 48000, Channels: 2}
	aacCodec  = &core.Codec{Name: core.CodecAAC, ClockRate: 16000, Channels: 1}
)

// Frames 50 ms apart, then 5 s the camera never sent, then on: the frame before the pause stays on screen for it,
// and every frame starts at its own time since the first.
func TestTimelineKeepsAPauseAsAStillFrame(t *testing.T) {
	m := newMuxer(true, h264Codec)
	const base = 1_000_000
	times := []uint32{0, 4500, 9000, 459000, 463500, 468000}
	var got []written
	for i, ts := range times {
		if b := m.GetPayload(0, packet(base+ts, byte(i))); b != nil {
			got = append(got, decode(t, b))
		} else if i != 0 {
			t.Fatalf("frame %d: nothing written", i)
		}
	}
	if len(got) != len(times)-1 {
		t.Fatalf("written %d, want %d (the newest frame waits for the next)", len(got), len(times)-1)
	}
	for i, w := range got {
		if w.payload != byte(i) || w.dts != times[i] || w.duration != times[i+1]-times[i] {
			t.Fatalf("frame %d: %+v, want dts %d duration %d", i, w, times[i], times[i+1]-times[i])
		}
	}
}

// Upstream (the live player) still cuts the same pause to 1 ms.
func TestLivePlayerStillCutsPauses(t *testing.T) {
	m := newMuxer(false, h264Codec)
	var last written
	for i, ts := range []uint32{0, 4500, 9000, 459000} {
		last = decode(t, m.GetPayload(0, packet(1_000_000+ts, byte(i))))
	}
	// The first frame's 91 is taken back from the second: 9000 is still the third frame's time.
	if last.duration != 91 || last.dts != 9000 {
		t.Fatalf("upstream behaviour changed: %+v", last)
	}
}

func TestTimelineTreatsJumpsAsANewClock(t *testing.T) {
	m := newMuxer(true, h264Codec)
	steps := []struct {
		ts   uint32
		want uint32 // duration written for the previous frame
	}{
		{1<<32 - 9000, 0},
		{1<<32 - 4500, 4500},
		{0, 4500}, // RTP time wraps around
		{4500, 4500},
		{4500, 91},                     // the same time again: upstream's minimum
		{1000, 91},                     // a step back: the source's clock started again
		{1000 + 61*90000, 91},          // over a minute ahead: a new clock, not a pause
		{1000 + 61*90000 + 4500, 4500}, // and on from there
	}
	for i, s := range steps {
		b := m.GetPayload(0, packet(s.ts, byte(i)))
		if i == 0 {
			continue
		}
		if w := decode(t, b); w.duration != s.want {
			t.Fatalf("step %d: duration %d, want %d", i, w.duration, s.want)
		}
	}
}

// Each track waits for its own next sample; sound and picture keep their own time.
func TestTimelineTracksAreIndependent(t *testing.T) {
	m := newMuxer(true, h264Codec, opusCodec)
	if m.GetPayload(0, packet(0, 0)) != nil || m.GetPayload(1, packet(0, 0)) != nil {
		t.Fatal("the first sample of each track waits")
	}
	if w := decode(t, m.GetPayload(1, packet(1920, 1))); w.track != 2 || w.duration != 1920 {
		t.Fatalf("audio: %+v", w)
	}
	if w := decode(t, m.GetPayload(0, packet(90000, 1))); w.track != 1 || w.duration != 90000 {
		t.Fatalf("video after 1 s: %+v", w)
	}
}

// AAC keeps upstream's 1024 per frame, except when frames are missing.
func TestTimelineAAC(t *testing.T) {
	m := newMuxer(true, aacCodec)
	var got []uint32
	for i, ts := range []uint32{0, 1030, 2040, 3072, 3072 + 4*1024, 3072 + 5*1024} {
		if b := m.GetPayload(0, packet(ts, byte(i))); b != nil {
			got = append(got, decode(t, b).duration)
		}
	}
	want := []uint32{1024, 1024, 1024, 4096, 1024}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("durations %v, want %v", got, want)
		}
	}
}

func TestTimelineCopiesTheHeldPayload(t *testing.T) {
	m := newMuxer(true, h264Codec)
	p := packet(0, 7)
	m.GetPayload(0, p)
	p.Payload[5] = 9 // the source reuses its buffer
	if w := decode(t, m.GetPayload(0, packet(4500, 8))); w.payload != 7 {
		t.Fatalf("held frame changed: %d", w.payload)
	}
}
