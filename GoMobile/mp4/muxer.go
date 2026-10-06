// Waiting Paws copy of go2rtc v1.9.14 pkg/mp4/muxer.go, put in place by GoMobile/build.sh.
// go2rtc is MIT License, Copyright (c) 2022 Alexey Khit (full text: App/Resources/Legal/Acknowledgements.txt).
// Changes against upstream (search for "Waiting Paws"): a consumer can keep the source's timeline (KeepTimeline, used
// by /api/stream.mp4, which the app records). Upstream gives every sample the time since the previous one and cuts any
// pause over 1 s down to 1 ms. That suits a live player, which shouldn't show a still frame for seconds, but a file
// then loses the pause: the picture runs ahead of the sound and of the clock (32 s by the end of a 4-minute recording
// during 4–10 s camera stalls, 6 s in a healthy 45 minutes). Here each sample is held until the next one arrives and
// lasts until it, so a pause stays in the file as a still frame at the time it happened.
package mp4

import (
	"bytes"
	"encoding/hex"

	"github.com/AlexxIT/go2rtc/pkg/core"
	"github.com/AlexxIT/go2rtc/pkg/h264"
	"github.com/AlexxIT/go2rtc/pkg/h265"
	"github.com/AlexxIT/go2rtc/pkg/iso"
	"github.com/pion/rtp"
)

type Muxer struct {
	index  uint32
	dts    []uint64
	pts    []uint32
	codecs []*core.Codec

	timeline bool          // Waiting Paws: keep the source's timeline
	held     []*rtp.Packet // with `timeline`: each track's newest sample, written when the next one arrives
}

// KeepTimeline (Waiting Paws) makes the consumer keep the source's pauses in the file instead of cutting them out.
// It costs one frame of delay, and the last sample of each track is never written.
func (c *Consumer) KeepTimeline() {
	c.muxer.timeline = true
}

func (m *Muxer) AddTrack(codec *core.Codec) {
	m.dts = append(m.dts, 0)
	m.pts = append(m.pts, 0)
	m.held = append(m.held, nil)
	m.codecs = append(m.codecs, codec)
}

func (m *Muxer) GetInit() ([]byte, error) {
	mv := iso.NewMovie(1024)
	mv.WriteFileType()

	mv.StartAtom(iso.Moov)
	mv.WriteMovieHeader()

	for i, codec := range m.codecs {
		switch codec.Name {
		case core.CodecH264:
			sps, pps := h264.GetParameterSet(codec.FmtpLine)
			// some dummy SPS and PPS not a problem for MP4, but problem for HLS :(
			if len(sps) == 0 {
				sps = []byte{0x67, 0x42, 0x00, 0x0a, 0xf8, 0x41, 0xa2}
			}
			if len(pps) == 0 {
				pps = []byte{0x68, 0xce, 0x38, 0x80}
			}

			var width, height uint16
			if s := h264.DecodeSPS(sps); s != nil {
				width = s.Width()
				height = s.Height()
			} else {
				width = 1920
				height = 1080
			}

			mv.WriteVideoTrack(
				uint32(i+1), codec.Name, codec.ClockRate, width, height, h264.EncodeConfig(sps, pps),
			)

		case core.CodecH265:
			vps, sps, pps := h265.GetParameterSet(codec.FmtpLine)
			// some dummy SPS and PPS not a problem
			if len(vps) == 0 {
				vps = []byte{0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x01, 0x40, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x99, 0xac, 0x09}
			}
			if len(sps) == 0 {
				sps = []byte{0x42, 0x01, 0x01, 0x01, 0x40, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x99, 0xa0, 0x01, 0x40, 0x20, 0x05, 0xa1, 0xfe, 0x5a, 0xee, 0x46, 0xc1, 0xae, 0x55, 0x04}
			}
			if len(pps) == 0 {
				pps = []byte{0x44, 0x01, 0xc0, 0x73, 0xc0, 0x4c, 0x90}
			}

			var width, height uint16
			if s := h265.DecodeSPS(sps); s != nil {
				width = s.Width()
				height = s.Height()
			} else {
				width = 1920
				height = 1080
			}

			mv.WriteVideoTrack(
				uint32(i+1), codec.Name, codec.ClockRate, width, height, h265.EncodeConfig(vps, sps, pps),
			)

		case core.CodecAAC:
			s := core.Between(codec.FmtpLine, "config=", ";")
			b, err := hex.DecodeString(s)
			if err != nil {
				return nil, err
			}

			mv.WriteAudioTrack(
				uint32(i+1), codec.Name, codec.ClockRate, uint16(codec.Channels), b,
			)

		case core.CodecOpus, core.CodecMP3, core.CodecPCMA, core.CodecPCMU, core.CodecFLAC:
			mv.WriteAudioTrack(
				uint32(i+1), codec.Name, codec.ClockRate, uint16(codec.Channels), nil,
			)
		}
	}

	mv.StartAtom(iso.MoovMvex)
	for i := range m.codecs {
		mv.WriteTrackExtend(uint32(i + 1))
	}
	mv.EndAtom() // MVEX

	mv.EndAtom() // MOOV

	return mv.Bytes(), nil
}

func (m *Muxer) Reset() {
	m.index = 0
	for i := range m.dts {
		m.dts[i] = 0
		m.pts[i] = 0
		m.held[i] = nil
	}
}

func (m *Muxer) GetPayload(trackID byte, packet *rtp.Packet) []byte {
	if m.timeline {
		return m.heldPayload(trackID, packet)
	}

	duration := packet.Timestamp - m.pts[trackID]
	m.pts[trackID] = packet.Timestamp

	return m.fragment(trackID, packet, duration, false)
}

// maxPause is the longest pause a file keeps, in seconds (Waiting Paws). A longer jump in a source's time is a new
// clock rather than a pause: a reconnected RTSP session starts its RTP time anywhere. The app's recorder gives up on a
// stream that sends nothing for 30 s, and the camera's own clock keeps counting across a reconnect.
const maxPause = 60

// heldPayload (Waiting Paws) writes the track's previous sample now that this one tells how long it lasted.
// Returns nil for the first sample of a track.
func (m *Muxer) heldPayload(trackID byte, packet *rtp.Packet) []byte {
	prev := m.held[trackID]
	// The payload is copied: it may share a buffer the source reuses.
	m.held[trackID] = &rtp.Packet{Header: packet.Header, Payload: bytes.Clone(packet.Payload)}
	if prev == nil {
		return nil
	}

	codec := m.codecs[trackID]
	duration := packet.Timestamp - prev.Timestamp // RTP time wraps around, so a step back is a huge number
	switch {
	case duration == 0 || duration > maxPause*codec.ClockRate:
		duration = codec.ClockRate/1000 + 1 // a new clock: upstream's minimum
	case codec.Name == core.CodecAAC && duration < 2*1024:
		duration = 1024 // upstream: important for Apple Finder and QuickTime. A longer step means lost frames.
	}
	return m.fragment(trackID, prev, duration, true)
}

// fragment is upstream's GetPayload after working out the duration (Waiting Paws). An `exact` duration (a held
// sample's) is written as is, without upstream's limits.
func (m *Muxer) fragment(trackID byte, packet *rtp.Packet, duration uint32, exact bool) []byte {
	codec := m.codecs[trackID]

	m.index++

	// flags important for Apple Finder video preview
	var flags uint32

	switch codec.Name {
	case core.CodecH264:
		if h264.IsKeyframe(packet.Payload) {
			flags = iso.SampleVideoIFrame
		} else {
			flags = iso.SampleVideoNonIFrame
		}
	case core.CodecH265:
		if h265.IsKeyframe(packet.Payload) {
			flags = iso.SampleVideoIFrame
		} else {
			flags = iso.SampleVideoNonIFrame
		}
	case core.CodecAAC:
		if !exact {
			duration = 1024 // important for Apple Finder and QuickTime
		}
		flags = iso.SampleAudio // not important?
	default:
		flags = iso.SampleAudio // important for FLAC on Android Telegram
	}

	// minumum duration important for MSE in Apple Safari
	if !exact && (duration == 0 || duration > codec.ClockRate) {
		duration = codec.ClockRate/1000 + 1
		m.pts[trackID] += duration
	}

	size := len(packet.Payload)

	mv := iso.NewMovie(1024 + size)
	mv.WriteMovieFragment(
		// ExtensionProfile - wrong place for CTS (supported by mpegts.Demuxer)
		m.index, uint32(trackID+1), duration, uint32(size), flags, m.dts[trackID], uint32(packet.ExtensionProfile),
	)
	mv.WriteData(packet.Payload)

	//log.Printf("[MP4] idx:%3d trk:%d dts:%6d cts:%4d dur:%5d time:%10d len:%5d", m.index, trackID+1, m.dts[trackID], packet.SSRC, duration, packet.Timestamp, len(packet.Payload))

	m.dts[trackID] += uint64(duration)

	return mv.Bytes()
}
