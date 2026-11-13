package p2p

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/pion/stun/v3"
)

// doorEvents records a door's datagrams and states.
type doorEvents struct {
	mu        sync.Mutex
	datagrams []doorDatagram
	states    []DoorStatus
	onData    func(from string, payload []byte)
}

type doorDatagram struct {
	from    string
	payload string
}

func (e *doorEvents) Datagram(from string, payload []byte) {
	e.mu.Lock()
	e.datagrams = append(e.datagrams, doorDatagram{from, string(payload)})
	on := e.onData
	e.mu.Unlock()
	if on != nil {
		on(from, payload)
	}
}

func (e *doorEvents) State(status string) {
	var s DoorStatus
	if err := json.Unmarshal([]byte(status), &s); err != nil {
		panic(err)
	}
	e.mu.Lock()
	e.states = append(e.states, s)
	e.mu.Unlock()
}

func (e *doorEvents) got() []doorDatagram {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]doorDatagram{}, e.datagrams...)
}

func openTestDoor(t *testing.T, opts DoorOptions) (*Door, *doorEvents) {
	t.Helper()
	opts.Loopback = true
	if opts.KeepAlive == 0 {
		opts.KeepAlive = -1
	}
	events := &doorEvents{}
	door, err := OpenDoor(opts, events)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(door.Close)
	return door, events
}

func doorAddr(d *Door) string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.status.Local
}

func doorPort(d *Door) int {
	_, port, _ := net.SplitHostPort(doorAddr(d))
	n, _ := strconv.Atoi(port)
	return n
}

func eventually(t *testing.T, what string, timeout time.Duration, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no %s in %v", what, timeout)
}

// portRestricted is the home router as measured (2026-11-13): a packet gets in only from an ip:port this side sent to.
type portRestricted struct {
	net.PacketConn
	mu     sync.Mutex
	sentTo map[string]bool
	drops  int
}

func (p *portRestricted) WriteTo(b []byte, addr net.Addr) (int, error) {
	p.mu.Lock()
	p.sentTo[addr.String()] = true
	p.mu.Unlock()
	return p.PacketConn.WriteTo(b, addr)
}

func (p *portRestricted) ReadFrom(b []byte) (int, net.Addr, error) {
	for {
		n, addr, err := p.PacketConn.ReadFrom(b)
		if err != nil {
			return n, addr, err
		}
		p.mu.Lock()
		open := p.sentTo[addr.String()]
		if !open {
			p.drops++
		}
		p.mu.Unlock()
		if open {
			return n, addr, nil
		}
	}
}

// behindStrictRouter opens a door whose socket only takes what the router lets in.
func behindStrictRouter(t *testing.T) (*Door, *doorEvents, *portRestricted) {
	t.Helper()
	var router *portRestricted
	doorConnWrap = func(conn net.PacketConn) net.PacketConn {
		router = &portRestricted{PacketConn: conn, sentTo: map[string]bool{}}
		return router
	}
	door, events := openTestDoor(t, DoorOptions{})
	doorConnWrap = nil
	return door, events, router
}

// A knock reaches a door behind the strict router only once that door sprayed the knocker's port; junk and the
// spray's own packets never reach the app.
func TestDoorKnockGetsInOnlyAfterSpray(t *testing.T) {
	mac, macEvents, router := behindStrictRouter(t)
	phone, phoneEvents := openTestDoor(t, DoorOptions{})
	other, _ := openTestDoor(t, DoorOptions{})

	if err := phone.Send(doorAddr(mac), []byte("knock 1")); err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	if got := macEvents.got(); len(got) != 0 {
		t.Fatalf("a knock got through the router before any spray: %v", got)
	}

	port := doorPort(phone)
	if err := mac.Spray("127.0.0.1", port-3, port+3, time.Second); err != nil {
		t.Fatal(err)
	}
	eventually(t, "spray", 2*time.Second, func() bool { return mac.sprayed.Load() >= 7 })
	if err := phone.Send(doorAddr(mac), []byte("knock 2")); err != nil {
		t.Fatal(err)
	}
	eventually(t, "knock", 2*time.Second, func() bool { return len(macEvents.got()) == 1 })
	if got := macEvents.got()[0]; got.payload != "knock 2" || got.from != doorAddr(phone) {
		t.Fatalf("got %+v", got)
	}
	if len(phoneEvents.got()) != 0 {
		t.Fatalf("the spray reached the app: %v", phoneEvents.got())
	}

	// A port outside the sprayed range stays shut out.
	if err := other.Send(doorAddr(mac), []byte("knock 3")); err != nil {
		t.Fatal(err)
	}
	// The answer goes back the way the knock came.
	if err := mac.Send(doorAddr(phone), []byte("answer")); err != nil {
		t.Fatal(err)
	}
	eventually(t, "answer", 2*time.Second, func() bool { return len(phoneEvents.got()) == 1 })
	conn, err := net.Dial("udp4", doorAddr(mac))
	if err != nil {
		t.Fatal(err)
	}
	_, _ = conn.Write([]byte("junk"))
	_ = conn.Close()
	time.Sleep(200 * time.Millisecond)
	if got := macEvents.got(); len(got) != 1 {
		t.Fatalf("let in: %v", got)
	}
	router.mu.Lock()
	drops := router.drops
	router.mu.Unlock()
	if drops < 2 {
		t.Fatalf("the router dropped %d, not the first knock and the other port's", drops)
	}

	if err := mac.Spray("", 0, 0, 0); err != nil {
		t.Fatal(err)
	}
	if status := mac.StatusJSON(); json.Valid([]byte(status)) == false {
		t.Fatal(status)
	}
}

// The door learns its address from the internet from a STUN server, and keeps asking.
func TestDoorLearnsItsAddressFromSTUN(t *testing.T) {
	server, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	asks := 0
	var mu sync.Mutex
	go func() {
		buf := make([]byte, 1500)
		for {
			n, from, err := server.ReadFromUDP(buf)
			if err != nil {
				return
			}
			msg := &stun.Message{Raw: append([]byte{}, buf[:n]...)}
			if msg.Decode() != nil {
				continue
			}
			mu.Lock()
			asks++
			mu.Unlock()
			answer := stun.MustBuild(stun.NewTransactionIDSetter(msg.TransactionID), stun.BindingSuccess,
				&stun.XORMappedAddress{IP: net.IPv4(203, 0, 113, 7), Port: 40001})
			_, _ = server.WriteToUDP(answer.Raw, from)
		}
	}()
	door, events := openTestDoor(t, DoorOptions{STUN: []string{"stun:" + server.LocalAddr().String()}, KeepAlive: 0.2})
	eventually(t, "external address", 3*time.Second, func() bool {
		events.mu.Lock()
		defer events.mu.Unlock()
		return len(events.states) > 0 && events.states[len(events.states)-1].External == "203.0.113.7:40001"
	})
	eventually(t, "keep-alive asks", 3*time.Second, func() bool { mu.Lock(); defer mu.Unlock(); return asks >= 3 })
	var status DoorStatus
	_ = json.Unmarshal([]byte(door.StatusJSON()), &status)
	if status.External != "203.0.113.7:40001" {
		t.Fatalf("%+v", status)
	}
}

// After a relaunch away from home: the iPhone's new link is signalled only through the doors (the Mac's behind the
// strict router, opened by its spray), connects, and carries a stream to the Mac's service.
func TestLinkSignalledThroughTheDoors(t *testing.T) {
	mac, macEvents, _ := behindStrictRouter(t)
	phone, phoneEvents := openTestDoor(t, DoorOptions{})

	web := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "picture") }))
	defer web.Close()
	opts := Options{Label: "out", PingInterval: 0.2, Interfaces: []string{"lo"}, Loopback: true}
	answer := opts
	answer.Services = map[string]string{"go2rtc": web.Listener.Addr().String()}
	answer.Role, opts.Role = "answer", "offer"

	oe, ae := &doorSignals{name: "iphone"}, &doorSignals{name: "mac"}
	o, err := NewLink(opts, oe)
	if err != nil {
		t.Fatal(err)
	}
	a, err := NewLink(answer, ae)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { o.Close(); a.Close() })
	var knockFrom string
	var size int
	var once sync.Once
	// iPhone → its door → the Mac's door; the Mac answers to where the knock came from.
	oe.send = func(message string) {
		size = len(message)
		_ = phone.Send(doorAddr(mac), []byte(message))
	}
	macEvents.onData = func(from string, payload []byte) {
		once.Do(func() {
			knockFrom = from
			go func() {
				if err := a.HandleSignal(string(payload)); err != nil {
					panic(err)
				}
			}()
		})
	}
	ae.send = func(message string) { _ = mac.Send(knockFrom, []byte(message)) }
	phoneEvents.onData = func(_ string, payload []byte) {
		go func() { _ = o.HandleSignal(string(payload)) }()
	}

	_ = mac.Spray("127.0.0.1", doorPort(phone)-8, doorPort(phone)+8, time.Second)
	eventually(t, "spray", 2*time.Second, func() bool { return mac.sprayed.Load() > 0 })
	port, err := o.Forward("go2rtc", 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := o.Start(); err != nil {
		t.Fatal(err)
	}
	eventually(t, "connection", 20*time.Second, func() bool { s := oe.status(); return s.State == "connected" && s.Pongs > 0 })
	t.Logf("the offer was %d bytes", size)
	resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/", port))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if string(body) != "picture" {
		t.Fatalf("got %q", body)
	}
}

// doorSignals sends a link's signals with `send`, and keeps its last status.
type doorSignals struct {
	mu   sync.Mutex
	name string
	send func(string)
	last Status
}

func (e *doorSignals) Signal(message string) {
	e.mu.Lock()
	send := e.send
	e.mu.Unlock()
	send(message)
}

func (e *doorSignals) State(status string) {
	var s Status
	_ = json.Unmarshal([]byte(status), &s)
	e.mu.Lock()
	e.last = s
	e.mu.Unlock()
}

func (e *doorSignals) status() Status {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.last
}

// P2P_NET=1: a door on this machine's LAN interface learns its address from the internet, and keeps it (the home
// router's mapping of a fixed port stays while it is asked every few seconds).
func TestDoorOnTheRealNetwork(t *testing.T) {
	if os.Getenv("P2P_NET") != "1" {
		t.Skip("P2P_NET=1 for the network")
	}
	iface := os.Getenv("P2P_IFACE")
	events := &doorEvents{}
	door, err := OpenDoor(DoorOptions{Port: 41984, Interface: iface, KeepAlive: 2,
		STUN: []string{"stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"}}, events)
	if err != nil {
		t.Fatal(err)
	}
	defer door.Close()
	var first string
	eventually(t, "external address", 6*time.Second, func() bool {
		var s DoorStatus
		_ = json.Unmarshal([]byte(door.StatusJSON()), &s)
		first = s.External
		return first != ""
	})
	time.Sleep(5 * time.Second)
	var s DoorStatus
	_ = json.Unmarshal([]byte(door.StatusJSON()), &s)
	t.Logf("door %s is %s from the internet (then %s)", s.Local, first, s.External)
	if s.External != first {
		t.Fatalf("the address changed between asks: %s → %s", first, s.External)
	}
}
