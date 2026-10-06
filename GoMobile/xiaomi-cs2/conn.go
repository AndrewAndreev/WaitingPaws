// Waiting Paws copy of go2rtc v1.9.14 pkg/xiaomi/miss/cs2/conn.go, put in place by GoMobile/build.sh.
// go2rtc is MIT License, Copyright (c) 2022 Alexey Khit (full text: App/Resources/Legal/Acknowledgements.txt).
// Changes against upstream (search for "Waiting Paws"):
//   - the UDP socket gets a 4 MB receive buffer: the system default (768 KB) overflowed during keyframe bursts
//     and every lost datagram stalled the picture until the camera resent it;
//   - the media channel keeps up to 2048 out-of-order packets (upstream 250) and pops up to 1000 (upstream 100):
//     while one packet is missing the rest are still acknowledged, so the camera doesn't resend them too;
//   - the command channel holds 100 messages and a full queue drops a message instead of killing the connection;
//   - "cs2: unknown msg" is not printed;
//   - UDP is preferred unless the source says `transport=tcp`, and the transport is a preference: a camera that
//     doesn't offer it connects with its own choice instead of failing. The C302 picks TCP by itself, and there a
//     packet lost on Wi-Fi held the whole stream for 1–1.5 s until TCP resent it; over UDP CS2 makes up for a loss in
//     a few ms (same camera, same minutes: longest pause 0.2–0.45 s on UDP, 1.2–1.45 s on TCP). The log says which;
//   - a camera that struggles over UDP (a missing packet holds the video for 3 s: on a slow link the camera resends
//     before our acknowledgements arrive, a third of the traffic is resends, and it ends in a stall) is reconnected
//     over TCP, which paces itself to the link, and asked for TCP for an hour (`transport=udp` in the source keeps UDP);
//   - every 30 s the log gets the video's timing when it was uneven (and once, 30 s after connecting, in any case):
//     frames, bitrate, the longest pause between frames with the camera's own time for that pause (a pause in
//     arrival only = delivery held up; in camera time too = frames never sent), the spread of delivery against the
//     camera's clock (the cushion a player needs) and, over UDP, the resend counters.
package cs2

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

func Dial(host, transport string) (*Conn, error) {
	started := time.Now()
	if transport == "" && strugglingOverUDP(host) {
		logf("cs2: %s struggled over UDP lately, asking for TCP", host)
		transport = "tcp"
	}
	conn, err := handshake(host, transport)
	if err != nil {
		return nil, err
	}

	_, isTCP := conn.(*tcpConn)

	c := &Conn{
		Conn:  conn,
		isTCP: isTCP,
		host:  host,
		channels: [4]*dataChannel{
			newDataChannel(0, 100), nil, newDataChannel(2048, 1000), nil,
		},
		done: make(chan struct{}),
	}
	c.channels[2].timing = true
	go c.worker()
	go c.report()
	go c.watch()
	logf("cs2: connected to %s over %s in %d ms", conn.RemoteAddr(), c.transport(), time.Since(started).Milliseconds())
	return c, nil
}

func logf(format string, args ...any) {
	_, _ = fmt.Fprintf(os.Stderr, "%s "+format+"\n", append([]any{time.Now().Format("15:04:05")}, args...)...)
}

func (c *Conn) transport() string {
	if c.isTCP {
		return "TCP"
	}
	return "UDP"
}

// Cameras that struggled over UDP, by host: asked for TCP for an hour (Waiting Paws).
var udpTrouble sync.Map

func strugglingOverUDP(host string) bool {
	at, ok := udpTrouble.Load(host)
	return ok && time.Since(at.(time.Time)) < time.Hour
}

// watch drops a UDP connection whose video a missing packet has held up for 3 s (Waiting Paws): go2rtc reconnects at
// once, and the camera is asked for TCP from then on.
func (c *Conn) watch() {
	if c.isTCP {
		return
	}
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-ticker.C:
			if held := c.channels[2].heldUp(); held >= 3*time.Second {
				udpTrouble.Store(c.host, time.Now())
				logf("cs2: UDP to %s is struggling (a missing packet has held the video for %.1f s), reconnecting over TCP",
					c.host, held.Seconds())
				_ = c.Conn.Close()
				return
			}
		}
	}
}

// report logs the media channel's timing every 30 s (Waiting Paws): when a pause between frames could freeze a
// player, a missing packet held the stream up or a buffer overflowed, and once after connecting as a baseline.
func (c *Conn) report() {
	const window = 30 * time.Second
	ticker := time.NewTicker(window)
	defer ticker.Stop()
	first := true
	for {
		select {
		case <-c.done:
			return
		case <-ticker.C:
			s := c.channels[2].takeStats()
			// Over UDP a few resends every second are normal (the C302: ~5/s, each made up for in a few ms).
			trouble := s.refused > 0 || s.dropped > 0 || s.longestWait >= 300*time.Millisecond
			if !first && !trouble && s.longestPause < 700*time.Millisecond {
				continue
			}
			first = false
			line := fmt.Sprintf("cs2: 30s over %s: %d video frames (%.1f fps), %d kbit/s, longest pause %d ms "+
				"(camera time %d ms), delivery spread %d ms", c.transport(), s.frames, float64(s.frames)/window.Seconds(),
				s.videoBytes*8/int(window.Milliseconds()), s.longestPause.Milliseconds(), s.pauseCameraMs,
				s.maxOffset-s.minOffset)
			if !c.isTCP {
				line += fmt.Sprintf("; packets %d, out of order %d, refused %d, resent duplicates %d, "+
					"longest wait for a missing packet %d ms, most waiting %d",
					s.packets, s.outOfOrder, s.refused, s.duplicates, s.longestWait.Milliseconds(), s.maxWaiting)
			}
			if s.dropped > 0 {
				line += fmt.Sprintf("; dropped %d (queue full)", s.dropped)
			}
			logf("%s", line)
		}
	}
}

type Conn struct {
	net.Conn
	isTCP bool
	host  string

	err    error
	seqCh0 uint16
	seqCh3 uint16

	channels [4]*dataChannel
	done     chan struct{}

	cmdMu  sync.Mutex
	cmdAck func()
}

const (
	magic        = 0xF1
	magicDrw     = 0xD1
	magicTCP     = 0x68
	msgLanSearch = 0x30
	msgPunchPkt  = 0x41
	msgP2PRdyUDP = 0x42
	msgP2PRdyTCP = 0x43
	msgDrw       = 0xD0
	msgDrwAck    = 0xD1
	msgPing      = 0xE0
	msgPong      = 0xE1
	msgClose     = 0xF1
)

func handshake(host, transport string) (net.Conn, error) {
	conn, err := newUDPConn(host, 32108)
	if err != nil {
		return nil, err
	}

	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))

	req := []byte{magic, msgLanSearch, 0, 0}
	res, err := conn.(*udpConn).WriteUntil(req, func(res []byte) bool {
		return res[1] == msgPunchPkt
	})
	if err != nil {
		_ = conn.Close()
		return nil, err
	}

	// Waiting Paws: `transport` (UDP by default) is a preference, not a requirement. The camera answers with the
	// transport it likes (the C302: TCP); when another one was asked for, it gets a moment to offer that too,
	// otherwise its choice stands instead of failing the connection.
	if transport == "" {
		transport = "udp"
	}
	punch := res
	res, err = conn.(*udpConn).WriteUntil(punch, func(res []byte) bool {
		return res[1] == msgP2PRdyUDP || res[1] == msgP2PRdyTCP
	})
	if err != nil {
		_ = conn.Close()
		return nil, err
	}

	want := map[string]byte{"udp": msgP2PRdyUDP, "tcp": msgP2PRdyTCP}[transport]
	if want != 0 && res[1] != want {
		_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
		if other, err := conn.(*udpConn).WriteUntil(punch, func(res []byte) bool { return res[1] == want }); err == nil {
			res = other
		} else {
			offered := "UDP"
			if res[1] == msgP2PRdyTCP {
				offered = "TCP"
			}
			logf("cs2: %s asked for, the camera offers only %s", transport, offered)
		}
	}

	_ = conn.SetDeadline(time.Time{})

	if res[1] == msgP2PRdyTCP {
		_ = conn.Close()
		//host := fmt.Sprintf("%d.%d.%d.%d:%d", b[31], b[30], b[29], b[28], uint16(b[27])<<8|uint16(b[26]))
		return newTCPConn(conn.RemoteAddr().String())
	}

	return conn, nil
}

func (c *Conn) worker() {
	defer func() {
		c.channels[0].Close()
		c.channels[2].Close()
		close(c.done)
	}()

	var keepaliveTS time.Time // only for TCP

	buf := make([]byte, 1200)

	for {
		n, err := c.Conn.Read(buf)
		if err != nil {
			c.err = fmt.Errorf("%s: %w", "cs2", err)
			return
		}

		// 0  f1d0  magic
		// 2  005d  size = total size + 4
		// 4  d1    magic
		// 5  00    channel
		// 6  0000  seq
		switch buf[1] {
		case msgDrw:
			ch := buf[5]
			channel := c.channels[ch]

			if c.isTCP {
				// For TCP we should send ping every second to keep connection alive.
				// Based on PCAP analysis: official Mi Home app sends PING every ~1s.
				if now := time.Now(); now.After(keepaliveTS) {
					_, _ = c.Conn.Write([]byte{magic, msgPing, 0, 0})
					keepaliveTS = now.Add(time.Second)
				}

				err = channel.Push(buf[8:n])
			} else {
				var pushed int

				seqHI, seqLO := buf[6], buf[7]
				seq := uint16(seqHI)<<8 | uint16(seqLO)
				pushed, err = channel.PushSeq(seq, buf[8:n])

				if pushed >= 0 {
					// For UDP we should send ACK.
					ack := []byte{magic, msgDrwAck, 0, 6, magicDrw, ch, 0, 1, seqHI, seqLO}
					_, _ = c.Conn.Write(ack)
				}
			}

			if err != nil {
				c.err = fmt.Errorf("%s: %w", "cs2", err)
				return
			}

		case msgPing:
			_, _ = c.Conn.Write([]byte{magic, msgPong, 0, 0})
		case msgPong, msgP2PRdyUDP, msgP2PRdyTCP, msgClose: // skip it
		case msgDrwAck: // only for UDP
			if c.cmdAck != nil {
				c.cmdAck()
			}
		default:
			_ = n // unknown msg, ignored
		}
	}
}

func (c *Conn) Protocol() string {
	if c.isTCP {
		return "cs2+tcp"
	}
	return "cs2+udp"
}

func (c *Conn) Version() string {
	return "CS2"
}

func (c *Conn) Error() error {
	if c.err != nil {
		return c.err
	}
	return io.EOF
}

func (c *Conn) ReadCommand() (cmd uint32, data []byte, err error) {
	buf, ok := c.channels[0].Pop()
	if !ok {
		return 0, nil, c.Error()
	}
	cmd = binary.LittleEndian.Uint32(buf)
	data = buf[4:]
	return
}

func (c *Conn) WriteCommand(cmd uint32, data []byte) error {
	c.cmdMu.Lock()
	defer c.cmdMu.Unlock()

	req := marshalCmd(0, c.seqCh0, cmd, data)
	c.seqCh0++

	if c.isTCP {
		_, err := c.Conn.Write(req)
		return err
	}

	var repeat atomic.Int32
	repeat.Store(5)

	timeout := time.NewTicker(time.Second)
	defer timeout.Stop()

	c.cmdAck = func() {
		repeat.Store(0)
		timeout.Reset(1)
	}

	for {
		if _, err := c.Conn.Write(req); err != nil {
			return err
		}
		<-timeout.C
		r := repeat.Add(-1)
		if r < 0 {
			return nil
		}
		if r == 0 {
			return fmt.Errorf("%s: can't send command %d", "cs2", cmd)
		}
	}
}

const hdrSize = 32

func (c *Conn) ReadPacket() (hdr, payload []byte, err error) {
	data, ok := c.channels[2].Pop()
	if !ok {
		return nil, nil, c.Error()
	}
	return data[:hdrSize], data[hdrSize:], nil
}

func (c *Conn) WritePacket(hdr, payload []byte) error {
	const offset = 12

	n := hdrSize + uint32(len(payload))
	req := make([]byte, n+offset)
	req[0] = magic
	req[1] = msgDrw
	binary.BigEndian.PutUint16(req[2:], uint16(n+8))

	req[4] = magicDrw
	req[5] = 3 // channel
	binary.BigEndian.PutUint16(req[6:], c.seqCh3)
	c.seqCh3++
	binary.BigEndian.PutUint32(req[8:], n)
	copy(req[offset:], hdr)
	copy(req[offset+hdrSize:], hdr)

	_, err := c.Conn.Write(req)
	return err
}

func marshalCmd(channel byte, seq uint16, cmd uint32, payload []byte) []byte {
	size := len(payload)
	req := make([]byte, 4+4+4+4+size)

	// 1. message header (4 bytes)
	req[0] = magic
	req[1] = msgDrw
	binary.BigEndian.PutUint16(req[2:], uint16(4+4+4+size))

	// 2. drw? header (4 bytes)
	req[4] = magicDrw
	req[5] = channel
	binary.BigEndian.PutUint16(req[6:], seq)

	// 3. payload size (4 bytes)
	binary.BigEndian.PutUint32(req[8:], uint32(4+size))

	// 4. payload command (4 bytes)
	binary.BigEndian.PutUint32(req[12:], cmd)

	// 5. payload
	copy(req[16:], payload)

	return req
}

func newUDPConn(host string, port int) (net.Conn, error) {
	// We using raw net.UDPConn, because RemoteAddr should be changed during handshake.
	conn, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil, err
	}
	// Waiting Paws: room for a keyframe burst while the reader is busy (the system default is 768 KB).
	_ = conn.SetReadBuffer(4 << 20)

	addr, err := net.ResolveUDPAddr("udp", host)
	if err != nil {
		addr = &net.UDPAddr{IP: net.ParseIP(host), Port: port}
	}

	return &udpConn{UDPConn: conn, addr: addr}, nil
}

type udpConn struct {
	*net.UDPConn
	addr *net.UDPAddr
}

func (c *udpConn) Read(b []byte) (n int, err error) {
	var addr *net.UDPAddr
	for {
		n, addr, err = c.UDPConn.ReadFromUDP(b)
		if err != nil {
			return 0, err
		}

		if string(addr.IP) == string(c.addr.IP) || n >= 8 {
			//log.Printf("<- %x", b[:n])
			return
		}
	}
}

func (c *udpConn) Write(b []byte) (n int, err error) {
	//log.Printf("-> %x", b)
	return c.UDPConn.WriteToUDP(b, c.addr)
}

func (c *udpConn) RemoteAddr() net.Addr {
	return c.addr
}

func (c *udpConn) WriteUntil(req []byte, ok func(res []byte) bool) ([]byte, error) {
	var t *time.Timer
	t = time.AfterFunc(1, func() {
		if _, err := c.Write(req); err == nil && t != nil {
			t.Reset(time.Second)
		}
	})
	defer t.Stop()

	buf := make([]byte, 1200)

	for {
		n, addr, err := c.UDPConn.ReadFromUDP(buf)
		if err != nil {
			return nil, err
		}

		if string(addr.IP) != string(c.addr.IP) || n < 16 {
			continue // skip messages from another IP
		}

		if ok(buf[:n]) {
			c.addr.Port = addr.Port
			return buf[:n], nil
		}
	}
}

func newTCPConn(addr string) (net.Conn, error) {
	conn, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		return nil, err
	}
	return &tcpConn{conn.(*net.TCPConn), bufio.NewReader(conn)}, nil
}

type tcpConn struct {
	*net.TCPConn
	rd *bufio.Reader
}

func (c *tcpConn) Read(p []byte) (n int, err error) {
	tmp := make([]byte, 8)
	if _, err = io.ReadFull(c.rd, tmp); err != nil {
		return
	}
	n = int(binary.BigEndian.Uint16(tmp))
	if len(p) < n {
		return 0, fmt.Errorf("tcp: buffer too small")
	}
	_, err = io.ReadFull(c.rd, p[:n])
	//log.Printf("<- %x%x", tmp, p[:n])
	return
}

func (c *tcpConn) Write(req []byte) (n int, err error) {
	n = len(req)
	buf := make([]byte, 8+n)
	binary.BigEndian.PutUint16(buf, uint16(n))
	buf[2] = magicTCP
	copy(buf[8:], req)
	//log.Printf("-> %x", buf)
	_, err = c.TCPConn.Write(buf)
	return
}

func newDataChannel(pushSize, popSize int) *dataChannel {
	c := &dataChannel{}
	if pushSize > 0 {
		c.pushBuf = make(map[uint16][]byte, pushSize)
		c.pushSize = pushSize
	}
	if popSize >= 0 {
		c.popBuf = make(chan []byte, popSize)
	}
	return c
}

type dataChannel struct {
	waitSeq  uint16
	pushBuf  map[uint16][]byte
	pushSize int

	waitData []byte
	waitSize int
	popBuf   chan []byte

	statsMu   sync.Mutex
	stats     channelStats
	waitStart time.Time // when the first packet after a missing one arrived (under statsMu: `watch` reads it)

	timing      bool      // the media channel: note every video frame's arrival
	lastFrame   time.Time // arrival of the previous video frame
	lastFrameTS int64     // its capture time on the camera's clock, ms
}

type channelStats struct {
	packets, outOfOrder, refused, duplicates, dropped, maxWaiting int
	longestWait                                                   time.Duration

	frames, videoBytes   int
	longestPause         time.Duration // between two video frames arriving
	pauseCameraMs        int64         // the same two frames apart on the camera's clock
	minOffset, maxOffset int64         // arrival minus capture time, ms
}

// observe notes a video frame's arrival against the camera's clock (Waiting Paws). The miss header in front of every
// media message carries the codec at bytes 4–7 and the capture time in ms at 16–23 (not on the Dafang and the
// Loock V2, which go2rtc special-cases: their spread is meaningless).
func (c *dataChannel) observe(msg []byte) {
	if len(msg) < hdrSize {
		return
	}
	if codec := binary.LittleEndian.Uint32(msg[4:]); codec != 4 && codec != 5 { // H.264, H.265
		return
	}
	now := time.Now()
	ts := int64(binary.LittleEndian.Uint64(msg[16:]))
	offset := now.UnixMilli() - ts

	c.statsMu.Lock()
	defer c.statsMu.Unlock()
	s := &c.stats
	s.frames++
	s.videoBytes += len(msg)
	if !c.lastFrame.IsZero() {
		if pause := now.Sub(c.lastFrame); pause > s.longestPause {
			s.longestPause = pause
			s.pauseCameraMs = ts - c.lastFrameTS
		}
	}
	c.lastFrame, c.lastFrameTS = now, ts
	if s.frames == 1 {
		s.minOffset, s.maxOffset = offset, offset
	} else {
		s.minOffset, s.maxOffset = min(s.minOffset, offset), max(s.maxOffset, offset)
	}
}

func (c *dataChannel) count(update func(s *channelStats)) {
	c.statsMu.Lock()
	update(&c.stats)
	c.statsMu.Unlock()
}

// heldUp is how long the video has been waiting for a missing packet right now.
func (c *dataChannel) heldUp() time.Duration {
	c.statsMu.Lock()
	defer c.statsMu.Unlock()
	if c.waitStart.IsZero() {
		return 0
	}
	return time.Since(c.waitStart)
}

func (c *dataChannel) takeStats() channelStats {
	c.statsMu.Lock()
	defer c.statsMu.Unlock()
	s := c.stats
	c.stats = channelStats{}
	return s
}

func (c *dataChannel) Push(b []byte) error {
	c.waitData = append(c.waitData, b...)

	for len(c.waitData) > 4 {
		// Every new data starts with size. There can be several data inside one packet.
		if c.waitSize == 0 {
			c.waitSize = int(binary.BigEndian.Uint32(c.waitData))
			c.waitData = c.waitData[4:]
		}
		if c.waitSize > len(c.waitData) {
			break
		}

		if c.timing {
			c.observe(c.waitData[:c.waitSize])
		}
		select {
		case c.popBuf <- c.waitData[:c.waitSize]:
		default:
			// Waiting Paws: a full queue drops the message instead of failing the connection.
			c.count(func(s *channelStats) { s.dropped++ })
		}

		c.waitData = c.waitData[c.waitSize:]
		c.waitSize = 0
	}
	return nil
}

func (c *dataChannel) Pop() ([]byte, bool) {
	data, ok := <-c.popBuf
	return data, ok
}

func (c *dataChannel) Close() {
	close(c.popBuf)
}

// PushSeq returns how many seq were processed.
// Returns 0 if seq was saved or processed earlier.
// Returns -1 if seq could not be saved (buffer full or disabled).
func (c *dataChannel) PushSeq(seq uint16, data []byte) (int, error) {
	c.count(func(s *channelStats) { s.packets++ })
	diff := int16(seq - c.waitSeq)
	// Check if this is seq from the future.
	if diff > 0 {
		// Support disabled buffer.
		if c.pushSize == 0 {
			return -1, nil // couldn't save seq
		}
		// Check if we don't have this seq in the buffer.
		if c.pushBuf[seq] == nil {
			// Check if there is enough space in the buffer.
			if len(c.pushBuf) == c.pushSize {
				c.count(func(s *channelStats) { s.refused++ })
				return -1, nil // couldn't save seq
			}
			c.pushBuf[seq] = bytes.Clone(data)
			waiting := len(c.pushBuf)
			c.count(func(s *channelStats) {
				if c.waitStart.IsZero() {
					c.waitStart = time.Now()
				}
				s.outOfOrder++
				s.maxWaiting = max(s.maxWaiting, waiting)
			})
		}
		return 0, nil
	}

	// Check if this is seq from the past.
	if diff < 0 {
		c.count(func(s *channelStats) { s.duplicates++ })
		return 0, nil
	}

	c.count(func(s *channelStats) {
		if !c.waitStart.IsZero() {
			s.longestWait = max(s.longestWait, time.Since(c.waitStart))
			c.waitStart = time.Time{}
		}
	})

	for i := 1; ; i++ {
		if err := c.Push(data); err != nil {
			return i, err
		}
		c.waitSeq++
		// Check if we have next seq in the buffer.
		if data = c.pushBuf[c.waitSeq]; data != nil {
			delete(c.pushBuf, c.waitSeq)
		} else {
			return i, nil
		}
	}
}
