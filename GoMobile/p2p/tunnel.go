package p2p

import (
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/webrtc/v4"
)

// Streams: TCP connections carried over the link, each in a data channel of its own ("tcp/<service>", reliable and
// ordered). The iPhone (offerer) listens on 127.0.0.1 for a service of the Mac (Forward) and opens a channel on the
// current session for every connection; the Mac (answerer) dials that service's address from Options.Services for
// every channel that opens, and nothing else. The channel's DTLS keys are pinned by a description that travelled
// sealed by the pairing (sync v2), so only the paired peer reaches those services.
//
// This is how the camera's picture (the Mac's go2rtc) and the sync link itself keep going over the direct link when
// the home network is gone.

const streamPrefix = "tcp/"

const (
	streamChunk = 16 << 10
	// Reading the TCP side pauses while this much waits unacknowledged in the channel, until it drops to streamLow.
	streamHigh = 1 << 20
	streamLow  = 256 << 10
	// A stream whose TCP side ended still delivers what it has queued, for at most this long.
	streamDrain = 5 * time.Second
)

// streamCounters: what went through the link's streams, for Status.
type streamCounters struct {
	open     atomic.Int32
	opened   atomic.Int64
	bytesIn  atomic.Int64 // from the peer
	bytesOut atomic.Int64 // to the peer
}

// Forward (offerer): listens on 127.0.0.1:port (0: any free port) for the peer's service; every connection made to
// it goes over the current session's data channel to that service of the peer. Returns the port. The listener stays
// until Close; a connection made while the link is down is closed at once.
func (l *Link) Forward(service string, port int) (int, error) {
	if l.opts.Role != "offer" {
		return 0, errors.New("p2p: only the offerer forwards")
	}
	if service == "" || strings.ContainsAny(service, "/ ") {
		return 0, fmt.Errorf("p2p: service %q", service)
	}
	ln, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return 0, err
	}
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		_ = ln.Close()
		return 0, errors.New("p2p: closed")
	}
	l.listeners = append(l.listeners, ln)
	l.mu.Unlock()
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return // closed
			}
			go l.openStream(conn, service)
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

// openStream (offerer): a connection to a forwarded port gets a data channel of its own on the current session.
func (l *Link) openStream(conn net.Conn, service string) {
	l.mu.Lock()
	cur := l.cur
	up := !l.closed && cur.open() && (l.status.State == "connected" || l.status.State == "disconnected")
	l.mu.Unlock()
	if !up {
		_ = conn.Close()
		return
	}
	dc, err := cur.pc.CreateDataChannel(streamPrefix+service, nil)
	if err != nil {
		fmt.Printf("%s p2p: %s: stream %s: %v\n", clock(), l.opts.Label, service, err)
		_ = conn.Close()
		return
	}
	l.pipe(conn, dc)
}

// acceptStream (answerer): a stream channel from the peer is joined to its service's address, if it is one of
// Options.Services. Called from pion's data channel handler, before the channel's messages are read.
func (l *Link) acceptStream(dc *webrtc.DataChannel, service string) {
	addr := l.opts.Services[service]
	if addr == "" {
		fmt.Printf("%s p2p: %s: a stream to unknown service %q refused\n", clock(), l.opts.Label, service)
		_ = dc.Close()
		return
	}
	conn, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		fmt.Printf("%s p2p: %s: stream %s: %v\n", clock(), l.opts.Label, service, err)
		_ = dc.Close()
		return
	}
	l.pipe(conn, dc)
}

// pipe joins a TCP connection and a data channel until either ends.
func (l *Link) pipe(conn net.Conn, dc *webrtc.DataChannel) {
	counters := &l.streams
	counters.open.Add(1)
	counters.opened.Add(1)
	low := make(chan struct{}, 1)
	dc.SetBufferedAmountLowThreshold(streamLow)
	dc.OnBufferedAmountLow(func() {
		select {
		case low <- struct{}{}:
		default:
		}
	})
	var once sync.Once
	end := func() {
		once.Do(func() {
			_ = conn.Close()
			_ = dc.Close()
			counters.open.Add(-1)
			l.emit()
		})
	}
	dc.OnMessage(func(msg webrtc.DataChannelMessage) {
		counters.bytesIn.Add(int64(len(msg.Data)))
		// Blocking here holds this channel's reads, so a slow reader slows the peer's sender down (SCTP's window).
		if _, err := conn.Write(msg.Data); err != nil {
			end()
		}
	})
	dc.OnClose(end)
	dc.OnOpen(func() {
		l.emit()
		go func() {
			defer end()
			buf := make([]byte, streamChunk)
			for {
				n, err := conn.Read(buf)
				if n > 0 {
					for dc.BufferedAmount() > streamHigh {
						select {
						case <-low:
						case <-time.After(time.Second):
						}
						if dc.ReadyState() != webrtc.DataChannelStateOpen {
							return
						}
					}
					if dc.Send(buf[:n]) != nil { // pion copies the bytes
						return
					}
					counters.bytesOut.Add(int64(n))
				}
				if err != nil {
					// The TCP side ended (e.g. a response sent in full): what is queued still reaches the peer
					// before the channel closes.
					deadline := time.Now().Add(streamDrain)
					for dc.BufferedAmount() > 0 && dc.ReadyState() == webrtc.DataChannelStateOpen && time.Now().Before(deadline) {
						time.Sleep(20 * time.Millisecond)
					}
					return
				}
			}
		}()
	})
}

// closeListeners: the forwarded ports go with the link. Under l.mu.
func (l *Link) closeListeners() {
	for _, ln := range l.listeners {
		_ = ln.Close()
	}
	l.listeners = nil
}

// fillStreams: the streams' counters into the status. Under l.mu.
func (l *Link) fillStreams() {
	l.status.Streams = int(l.streams.open.Load())
	l.status.StreamsOpened = int(l.streams.opened.Load())
	l.status.BytesIn = l.streams.bytesIn.Load()
	l.status.BytesOut = l.streams.bytesOut.Load()
}
