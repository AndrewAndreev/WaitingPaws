package miss

// Run after ./GoMobile/build.sh: cd GoMobile/build/go2rtc && go test ./pkg/xiaomi/miss

import "testing"

// sendOpus runs Opus packets stamped `cameraMS` through `a` the way Producer.Start does (upstream adds 40 ms after each)
// and returns the RTP times, in ms from the first packet's camera time.
func sendOpus(a *audioClock, ts *uint32, cameraMS ...uint64) []int64 {
	var out []int64
	for _, ms := range cameraMS {
		*ts = a.follow(*ts, &Packet{CodecID: codecOPUS, Timestamp: ms})
		out = append(out, int64(*ts)/48-int64(TimeToRTP(cameraMS[0], 48000))/48)
		*ts += timestamp40ms
	}
	return out
}

// every returns `n` camera times `step` ms apart from `from`, each moved by `jitter(i)`.
func every(from uint64, n int, step uint64, jitter func(i int) int) []uint64 {
	out := make([]uint64, n)
	for i := range out {
		out[i] = uint64(int(from+uint64(i)*step) + jitter(i))
	}
	return out
}

func none(int) int { return 0 }

func cameraClock() *audioClock { return newAudioClock(&Client{model: "chuangmi.camera.046c04"}) }

func TestAudioClockCountsWhileTheCameraKeepsTime(t *testing.T) {
	a, ts := cameraClock(), uint32(0)
	// A camera stamps with a few ms of jitter: the count, not the stamps, times the packets.
	got := sendOpus(a, &ts, every(5_000_000, 100, 40, func(i int) int { return []int{0, 4, -3, 6, -5}[i%5] })...)
	for i, ms := range got {
		if ms != int64(i)*40 {
			t.Fatalf("packet %d at %d ms, want %d", i, ms, i*40)
		}
	}
}

func TestAudioClockSkipsPacketsTheCameraNeverSent(t *testing.T) {
	a, ts := cameraClock(), uint32(0)
	before := every(5_000_000, 50, 40, none)           // 2 s
	after := every(5_000_000+50*40+3000, 10, 40, none) // then 3 s lost
	got := sendOpus(a, &ts, append(before, after...)...)
	if ms := got[50]; ms != 50*40+3000 {
		t.Fatalf("first packet after the loss at %d ms, want %d", ms, 50*40+3000)
	}
	if ms := got[59]; ms != 59*40+3000 {
		t.Fatalf("and on from there: %d ms", ms)
	}
}

func TestAudioClockIgnoresSmallLossesAndUntrustedClocks(t *testing.T) {
	a, ts := cameraClock(), uint32(0)
	// Two packets lost (80 ms): not worth a jump.
	stamps := append(every(5_000_000, 30, 40, none), every(5_000_000+32*40, 5, 40, none)...)
	if got := sendOpus(a, &ts, stamps...); got[30] != 30*40 {
		t.Fatalf("80 ms loss moved the count to %d ms", got[30])
	}

	// A loss before 1 s of steady stamps: the clock isn't trusted yet.
	a, ts = cameraClock(), 0
	stamps = append(every(5_000_000, 10, 40, none), every(5_000_000+10*40+3000, 5, 40, none)...)
	if got := sendOpus(a, &ts, stamps...); got[10] != 10*40 {
		t.Fatalf("untrusted clock moved the count to %d ms", got[10])
	}

	// Stamps that don't step by 40 ms (not ms on the camera's clock) never get trusted.
	a, ts = cameraClock(), 0
	if got := sendOpus(a, &ts, every(5_000_000, 60, 40_000, none)...); got[59] != 59*40 {
		t.Fatalf("stamps in µs moved the count to %d ms", got[59])
	}
}

func TestAudioClockAfterReconnectAndRestart(t *testing.T) {
	// A reconnect makes a new Producer: its count starts at the camera's time, not at 0, so a recording that went on
	// through the reconnect keeps the pause in the sound as well as in the picture.
	a, ts := cameraClock(), uint32(0)
	first := a.follow(ts, &Packet{CodecID: codecOPUS, Timestamp: 7_000_000})
	if first != TimeToRTP(7_000_000, 48000) {
		t.Fatalf("first packet at %d, want the camera's time", first)
	}

	// The camera restarted (its clock went back to near 0): the count follows it back.
	a, ts = cameraClock(), 0
	stamps := append(every(5_000_000, 30, 40, none), every(1_000, 5, 40, none)...)
	sendOpus(a, &ts, stamps...)
	if want := TimeToRTP(1_000+5*40, 48000); ts != want {
		t.Fatalf("after the restart the count is at %d, want %d", ts, want)
	}
}

func TestAudioClockPCMAAndOtherPackets(t *testing.T) {
	a, ts := cameraClock(), uint32(0)
	pcma := func(ms uint64) {
		ts = a.follow(ts, &Packet{CodecID: codecPCMA, Timestamp: ms, Payload: make([]byte, 320)}) // 40 ms at 8 kHz
		ts += 320
	}
	for i := range uint64(30) {
		pcma(9_000_000 + i*40)
	}
	pcma(9_000_000 + 30*40 + 1000) // 1 s lost
	if want := TimeToRTP(9_000_000+30*40+1000, 8000) + 320; ts != want {
		t.Fatalf("PCMA after a loss: %d, want %d", ts, want)
	}
	if got := a.follow(123, &Packet{CodecID: codecH264, Timestamp: 1}); got != 123 {
		t.Fatalf("video changed: %d", got)
	}
}

func TestAudioClockLeavesArrivalTimesAlone(t *testing.T) {
	a := newAudioClock(&Client{model: ModelDafang})
	if got := a.follow(0, &Packet{CodecID: codecOPUS, Timestamp: 5_000_000}); got != 0 {
		t.Fatalf("Dafang's count doesn't start at 0: %d", got)
	}
}
