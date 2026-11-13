package p2p

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/stun/v3"
)

// Door: one UDP socket for what has to reach a side while no link to it is up — the iPhone's knock (its offer,
// sealed by the app with the pairing keys) after the app was relaunched or its link died away from home, and the
// Mac's answer back the same way. Then the link is set up as always (ICE between the links' own sockets).
//
// The Mac keeps its door on a fixed port, so the router's mapping of it stays (STUN every KeepAlive seconds also
// tells its address from the internet, which the iPhone keeps). A home router like the one measured (2026-11-13:
// endpoint-independent mapping, address- and port-dependent filtering) lets a packet in only from an ip:port the Mac
// sent to; the iPhone's new socket gets a new port from its carrier, so while the iPhone is gone the Mac sends a tiny
// packet from the door to every port of the carrier's range it used (Spray), which opens the router for them.
//
// Datagrams start with doorMagic and a kind byte: doorKnock carries the app's payload (opaque here), doorSpray
// nothing (dropped on arrival). STUN answers to the door's own asks are read too; anything else is dropped.
type Door struct {
	opts   DoorOptions
	events DoorEvents
	bound  *boundNet

	mu      sync.Mutex
	conn    net.PacketConn
	closed  bool
	status  DoorStatus
	stunTx  map[[stun.TransactionIDSize]byte]bool
	spray   *sprayTarget
	stop    chan struct{}
	limiter rateLimiter

	sprayed, received, sent atomic.Int64
	seq                     atomic.Uint64
}

// DoorOptions, as JSON from the app.
type DoorOptions struct {
	// The local port (0: any free one). Taken if free, else any.
	Port int `json:"port"`
	// The socket is bound to this interface (Options.Interface); empty: the default route.
	Interface string `json:"interface"`
	// STUN servers ("stun:host:port"): the door's address from the internet, and keeping the router's mapping.
	STUN []string `json:"stun"`
	// Seconds between STUN asks (25; 0 keeps the default, negative: never).
	KeepAlive float64 `json:"keepAlive"`
	// Loopback is fine for addresses (tests).
	Loopback bool `json:"loopback"`
}

// DoorEvents for the app (on Go's goroutines).
type DoorEvents interface {
	// A knock's payload, from ip:port.
	Datagram(from string, payload []byte)
	// The door's DoorStatus as JSON, whenever its address or spraying changes.
	State(status string)
}

// DoorStatus of a door, for the app.
type DoorStatus struct {
	// The socket's own address, and the one the STUN servers see (empty until one answers).
	Local    string `json:"local"`
	External string `json:"external,omitempty"`
	// "ip:from-to" while spraying.
	Spraying string `json:"spraying,omitempty"`
	Sprayed  int64  `json:"sprayed"`
	Received int64  `json:"received"`
	Sent     int64  `json:"sent"`
	Error    string `json:"error,omitempty"`
	Seq      uint64 `json:"seq"`
}

type sprayTarget struct {
	ip       net.IP
	from, to int
	every    time.Duration
	stop     chan struct{}
}

var doorMagic = []byte("WPd")

const (
	doorKnock byte = 'k'
	doorSpray byte = 's'
	// The most ports one Spray covers, and how often a knock may come in (a datagram that opens nothing still costs
	// the app a few decryptions).
	sprayMaxPorts  = 512
	doorMaxPerSec  = 40
	doorMaxPayload = 1400
)

// OpenDoor opens the socket and starts reading.
func OpenDoor(opts DoorOptions, events DoorEvents) (*Door, error) {
	if opts.KeepAlive == 0 {
		opts.KeepAlive = 25
	}
	bound, err := newBoundNet(opts.Interface)
	if err != nil {
		return nil, err
	}
	d := &Door{opts: opts, events: events, bound: bound, stunTx: map[[stun.TransactionIDSize]byte]bool{},
		stop: make(chan struct{}), limiter: rateLimiter{perSec: doorMaxPerSec}}
	conn, err := d.listen()
	if err != nil {
		return nil, err
	}
	d.conn = conn
	d.status.Local = conn.LocalAddr().String()
	go d.read(conn)
	if opts.KeepAlive > 0 && len(opts.STUN) > 0 {
		go d.keepAlive()
	}
	return d, nil
}

// listen: the door's port if it is free, else any.
func (d *Door) listen() (net.PacketConn, error) {
	ip := net.IPv4zero
	if d.opts.Loopback {
		ip = net.IPv4(127, 0, 0, 1)
	}
	conn, err := d.bound.ListenUDP("udp4", &net.UDPAddr{IP: ip, Port: d.opts.Port})
	if err != nil && d.opts.Port != 0 {
		conn, err = d.bound.ListenUDP("udp4", &net.UDPAddr{IP: ip})
	}
	if err != nil {
		return nil, err
	}
	if doorConnWrap != nil {
		return doorConnWrap(conn), nil
	}
	return conn, nil
}

// doorConnWrap (tests): the door's socket behind a simulated router.
var doorConnWrap func(net.PacketConn) net.PacketConn

// Send a knock's payload to ip:port.
func (d *Door) Send(address string, payload []byte) error {
	if len(payload) > doorMaxPayload {
		return fmt.Errorf("p2p: door: %d bytes is too much for one datagram", len(payload))
	}
	addr, err := net.ResolveUDPAddr("udp4", address)
	if err != nil {
		return err
	}
	d.mu.Lock()
	conn, closed := d.conn, d.closed
	d.mu.Unlock()
	if closed {
		return errors.New("p2p: door closed")
	}
	packet := append(append(append([]byte{}, doorMagic...), doorKnock), payload...)
	if _, err := conn.WriteTo(packet, addr); err != nil {
		return err
	}
	d.sent.Add(1)
	return nil
}

// Spray: every `every`, a tiny packet from the door to each port from..to of ip (at most sprayMaxPorts, from the
// middle out), until Spray is called again; an empty ip stops.
func (d *Door) Spray(ip string, from, to int, every time.Duration) error {
	d.mu.Lock()
	if d.spray != nil {
		close(d.spray.stop)
		d.spray = nil
		d.status.Spraying = ""
	}
	if ip == "" || d.closed {
		d.mu.Unlock()
		d.emit()
		return nil
	}
	target := net.ParseIP(ip).To4()
	if target == nil {
		d.mu.Unlock()
		return fmt.Errorf("p2p: door: spray needs an IPv4 address, not %q", ip)
	}
	if from < 1 {
		from = 1
	}
	if to > 65535 {
		to = 65535
	}
	if to < from {
		d.mu.Unlock()
		return fmt.Errorf("p2p: door: spray ports %d-%d", from, to)
	}
	if to-from+1 > sprayMaxPorts {
		middle := (from + to) / 2
		from, to = middle-sprayMaxPorts/2, middle+sprayMaxPorts/2-1
	}
	if every < time.Second {
		every = time.Second
	}
	s := &sprayTarget{ip: target, from: from, to: to, every: every, stop: make(chan struct{})}
	d.spray = s
	d.status.Spraying = fmt.Sprintf("%s:%d-%d", target, from, to)
	d.mu.Unlock()
	d.emit()
	go d.sprayLoop(s)
	return nil
}

func (d *Door) sprayLoop(s *sprayTarget) {
	packet := append(append([]byte{}, doorMagic...), doorSpray)
	ticker := time.NewTicker(s.every)
	defer ticker.Stop()
	for {
		d.mu.Lock()
		conn := d.conn
		d.mu.Unlock()
		for port := s.from; port <= s.to; port++ {
			if _, err := conn.WriteTo(packet, &net.UDPAddr{IP: s.ip, Port: port}); err == nil {
				d.sprayed.Add(1)
			}
		}
		select {
		case <-s.stop:
			return
		case <-d.stop:
			return
		case <-ticker.C:
		}
	}
}

// keepAlive asks a STUN server from the door now and every KeepAlive seconds: its address from the internet, and
// the router's mapping of the port stays.
func (d *Door) keepAlive() {
	ticker := time.NewTicker(time.Duration(d.opts.KeepAlive * float64(time.Second)))
	defer ticker.Stop()
	turn := 0
	for {
		server := d.opts.STUN[turn%len(d.opts.STUN)]
		turn++
		if addr, err := d.bound.ResolveUDPAddr("udp4", trimSTUN(server)); err == nil {
			msg := stun.MustBuild(stun.TransactionID, stun.BindingRequest)
			d.mu.Lock()
			if len(d.stunTx) > 16 { // asks nobody answered
				d.stunTx = map[[stun.TransactionIDSize]byte]bool{}
			}
			d.stunTx[msg.TransactionID] = true
			conn := d.conn
			d.mu.Unlock()
			_, _ = conn.WriteTo(msg.Raw, addr)
		}
		select {
		case <-d.stop:
			return
		case <-ticker.C:
		}
	}
}

func trimSTUN(url string) string {
	if len(url) > 5 && url[:5] == "stun:" {
		return url[5:]
	}
	return url
}

// read takes datagrams until Close. A socket the system took away (iOS reclaims an app's sockets while it is
// suspended: "socket is not connected") is opened again on the same port.
func (d *Door) read(conn net.PacketConn) {
	buf := make([]byte, 2048)
	for {
		n, from, err := conn.ReadFrom(buf)
		if err != nil {
			d.mu.Lock()
			closed := d.closed
			d.mu.Unlock()
			if closed {
				return
			}
			time.Sleep(time.Second)
			if conn = d.reopen(conn); conn == nil {
				return
			}
			continue
		}
		d.take(buf[:n], from)
	}
}

func (d *Door) reopen(old net.PacketConn) net.PacketConn {
	_ = old.Close()
	port := 0
	if addr, ok := old.LocalAddr().(*net.UDPAddr); ok {
		port = addr.Port
	}
	saved := d.opts.Port
	d.opts.Port = port
	conn, err := d.listen()
	d.opts.Port = saved
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		if conn != nil {
			_ = conn.Close()
		}
		return nil
	}
	if err != nil {
		d.status.Error = err.Error()
		fmt.Printf("%s p2p: door: %v\n", clock(), err)
		return nil
	}
	d.conn = conn
	d.status.Local = conn.LocalAddr().String()
	d.status.Error = ""
	fmt.Printf("%s p2p: door opened again on %s\n", clock(), d.status.Local)
	return conn
}

func (d *Door) take(data []byte, from net.Addr) {
	switch {
	case bytes.HasPrefix(data, doorMagic) && len(data) > len(doorMagic):
		if data[len(doorMagic)] != doorKnock || !d.limiter.allow() {
			return
		}
		d.received.Add(1)
		payload := append([]byte{}, data[len(doorMagic)+1:]...)
		d.events.Datagram(from.String(), payload)
	case stun.IsMessage(data):
		msg := &stun.Message{Raw: append([]byte{}, data...)}
		if msg.Decode() != nil {
			return
		}
		d.mu.Lock()
		ours := d.stunTx[msg.TransactionID]
		delete(d.stunTx, msg.TransactionID)
		d.mu.Unlock()
		var xor stun.XORMappedAddress
		if !ours || xor.GetFrom(msg) != nil {
			return
		}
		external := net.JoinHostPort(xor.IP.String(), strconv.Itoa(xor.Port))
		d.mu.Lock()
		changed := d.status.External != external
		d.status.External = external
		local := d.status.Local
		d.mu.Unlock()
		if changed {
			fmt.Printf("%s p2p: door %s is %s from the internet\n", clock(), local, external)
			d.emit()
		}
	}
}

// Close the door.
func (d *Door) Close() {
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		return
	}
	d.closed = true
	if d.spray != nil {
		close(d.spray.stop)
		d.spray = nil
	}
	close(d.stop)
	conn := d.conn
	d.mu.Unlock()
	_ = conn.Close()
}

// StatusJSON is the door's status now.
func (d *Door) StatusJSON() string {
	d.mu.Lock()
	status := d.status
	d.mu.Unlock()
	status.Sprayed, status.Received, status.Sent = d.sprayed.Load(), d.received.Load(), d.sent.Load()
	status.Seq = d.seq.Add(1)
	data, _ := json.Marshal(status)
	return string(data)
}

func (d *Door) emit() { d.events.State(d.StatusJSON()) }

// rateLimiter lets perSec events through per second.
type rateLimiter struct {
	mu     sync.Mutex
	perSec int
	second int64
	count  int
}

func (r *rateLimiter) allow() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now().Unix()
	if now != r.second {
		r.second, r.count = now, 0
	}
	r.count++
	return r.count <= r.perSec
}
