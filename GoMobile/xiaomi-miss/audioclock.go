// Waiting Paws addition to go2rtc v1.9.14 pkg/xiaomi/miss, put in place by GoMobile/build.sh, which also hooks it into
// Producer.Start (producer.go).
//
// Upstream times the camera's sound by counting: 40 ms per Opus packet, one sample per PCMA byte, from 0 on every
// connect. The picture carries the camera's own frame times. So audio packets the camera drops cut time out of the
// sound, and a reconnect (go2rtc reconnects without dropping its viewers) takes the sound back to 0 while the picture
// goes on from the camera's clock: in a recording, which keeps pauses (see GoMobile/mp4/muxer.go), the sound would play
// ahead of the picture from then on. audioClock keeps the count (a camera stamps its audio with a few ms of jitter, too
// uneven to time samples by), starts it at the camera's time and moves it there whenever the camera's clock runs ahead
// of it by more than 200 ms.
package miss

type audioClock struct {
	stamped bool   // the camera stamps audio on the clock it stamps video with
	started bool   // a packet has been timed
	lastMS  uint64 // the camera's time for the previous audio packet, ms
	steady  int    // audio packets in a row whose camera time stepped by about their own length
}

func newAudioClock(client *Client) *audioClock {
	// For these two ReadPacket uses the arrival time (Dafang stamps in seconds, the Loock V2 doesn't stamp audio).
	return &audioClock{stamped: client.model != ModelDafang && client.model != ModelLoockV2}
}

// steadyPackets of audio (1 s) in step with the camera's clock make it trusted for a jump: a camera whose stamps don't
// count ms the way this expects never gets there and keeps upstream's count.
const steadyPackets = 25

// follow returns the RTP time for `pkt`, given upstream's count `ts` for it. Other packets than audio get `ts` back.
func (a *audioClock) follow(ts uint32, pkt *Packet) uint32 {
	var rate, length uint64 // the codec's clock; the packet's own length on it
	switch pkt.CodecID {
	case codecPCMA:
		rate, length = 8000, uint64(len(pkt.Payload))
	case codecOPUS:
		rate, length = 48000, timestamp40ms
	default:
		return ts
	}
	if !a.stamped {
		return ts
	}

	camera := TimeToRTP(pkt.Timestamp, rate)
	lengthMS := length * 1000 / rate
	trusted := a.steady >= steadyPackets
	if step := pkt.Timestamp - a.lastMS; a.started && step >= lengthMS/2 && step <= lengthMS*3/2 {
		a.steady++
	} else {
		a.steady = 0
	}
	a.lastMS = pkt.Timestamp

	if !a.started {
		a.started = true
		return camera
	}
	if trusted {
		// Ahead by more than 200 ms: packets were lost. Up to a minute, as long a pause as a recording keeps. Behind by
		// more than 2 s: the camera's clock started again.
		if ahead := int64(int32(camera - ts)); ahead > int64(rate)/5 && ahead <= 60*int64(rate) || ahead < -2*int64(rate) {
			return camera
		}
	}
	return ts
}
