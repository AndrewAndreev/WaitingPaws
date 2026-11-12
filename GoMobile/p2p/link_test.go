package p2p

import (
	"encoding/json"
	"net"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/pion/stun/v3"
)

// events records a link's signals and states; deliver passes the signals to the peer, like the apps' link.
type events struct {
	mu      sync.Mutex
	name    string
	peer    *Link
	states  []Status
	signals int
}

func (e *events) Signal(message string) {
	e.mu.Lock()
	e.signals++
	peer := e.peer
	e.mu.Unlock()
	go func() {
		if err := peer.HandleSignal(message); err != nil {
			panic(e.name + ": " + err.Error())
		}
	}()
}

func (e *events) State(status string) {
	var s Status
	if err := json.Unmarshal([]byte(status), &s); err != nil {
		panic(err)
	}
	e.mu.Lock()
	e.states = append(e.states, s)
	e.mu.Unlock()
}

func (e *events) last() Status {
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.states) == 0 {
		return Status{}
	}
	return e.states[len(e.states)-1]
}

func (e *events) waitFor(t *testing.T, what string, timeout time.Duration, ok func(Status) bool) Status {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if s := e.last(); ok(s) {
			return s
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("%s: no %s in %v (last: %+v)", e.name, what, timeout, e.last())
	return Status{}
}

// pair makes an offering and an answering link wired to each other; no STUN unless P2P_STUN=1 (the network).
func pair(t *testing.T, offer, answer Options) (*Link, *events, *Link, *events) {
	t.Helper()
	if os.Getenv("P2P_STUN") == "1" {
		offer.STUN = []string{"stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"}
		answer.STUN = offer.STUN
	}
	offer.Role, answer.Role = "offer", "answer"
	oe, ae := &events{name: "offer"}, &events{name: "answer"}
	o, err := NewLink(offer, oe)
	if err != nil {
		t.Fatal(err)
	}
	a, err := NewLink(answer, ae)
	if err != nil {
		t.Fatal(err)
	}
	oe.peer, ae.peer = a, o
	t.Cleanup(func() { o.Close(); a.Close() })
	return o, oe, a, ae
}

func TestLinkConnectsAndPings(t *testing.T) {
	opts := Options{Label: "lan", PingInterval: 0.2, Interfaces: []string{"lo"}, Loopback: true}
	o, oe, _, ae := pair(t, opts, opts)
	if err := o.Start(); err != nil {
		t.Fatal(err)
	}
	connected := func(s Status) bool { return s.State == "connected" && s.Pongs >= 2 && s.Local != nil }
	got := oe.waitFor(t, "pongs", 20*time.Second, connected)
	ae.waitFor(t, "pongs", 5*time.Second, connected)
	t.Logf("offer: %s %s:%d ↔ %s %s:%d, rtt %.2f ms, local %v remote %v, nat %+v", got.Local.Type, got.Local.Address,
		got.Local.Port, got.Remote.Type, got.Remote.Address, got.Remote.Port, got.RTT, got.LocalTypes, got.RemoteTypes, got.NAT)
	if got.RTT <= 0 || got.RTTMin <= 0 || got.ConnectedAt == 0 {
		t.Fatalf("no round trip: %+v", got)
	}
	if got.LocalTypes["host"] == 0 || got.RemoteTypes["host"] == 0 {
		t.Fatalf("no host candidates counted: %v %v", got.LocalTypes, got.RemoteTypes)
	}
}

func TestRestartOverTheChannel(t *testing.T) {
	opts := Options{Label: "lan", PingInterval: 0.2, Interfaces: []string{"lo"}, Loopback: true}
	o, oe, _, ae := pair(t, opts, opts)
	if err := o.Start(); err != nil {
		t.Fatal(err)
	}
	oe.waitFor(t, "connection", 20*time.Second, func(s Status) bool { return s.State == "connected" && s.Pongs > 0 })
	oe.mu.Lock()
	before := oe.signals
	oe.mu.Unlock()
	if err := o.Restart(); err != nil {
		t.Fatal(err)
	}
	got := oe.waitFor(t, "restart", 20*time.Second, func(s Status) bool { return s.Gen == 1 && s.SignalPath == "channel" })
	ae.waitFor(t, "restart answer", 10*time.Second, func(s Status) bool { return s.Gen == 1 && s.SignalPath == "channel" })
	oe.mu.Lock()
	after := oe.signals
	oe.mu.Unlock()
	if after != before {
		t.Fatalf("the restart went over the apps' link (%d signals, was %d)", after, before)
	}
	pongs := got.Pongs
	oe.waitFor(t, "pongs after the restart", 10*time.Second, func(s Status) bool { return s.Pongs >= pongs+3 && s.State == "connected" })
}

func TestCloseTellsThePeer(t *testing.T) {
	opts := Options{Label: "lan", PingInterval: 0.2, Interfaces: []string{"lo"}, Loopback: true}
	o, oe, _, ae := pair(t, opts, opts)
	if err := o.Start(); err != nil {
		t.Fatal(err)
	}
	oe.waitFor(t, "connection", 20*time.Second, func(s Status) bool { return s.State == "connected" })
	o.Close()
	ae.waitFor(t, "close", 5*time.Second, func(s Status) bool { return s.State == "closed" })
}

func TestNoPathFailsInTime(t *testing.T) {
	// Every host candidate is private and NoPrivateHost drops them: no STUN, so there is no candidate at all.
	opts := Options{Label: "out", NoPrivateHost: true, ConnectTimeout: 2, Interfaces: []string{"lo", "en", "bridge"}}
	o, oe, _, _ := pair(t, opts, opts)
	if os.Getenv("P2P_STUN") == "1" {
		t.Skip("with STUN the srflx candidates may connect through the router (hairpin)")
	}
	if err := o.Start(); err != nil {
		t.Fatal(err)
	}
	got := oe.waitFor(t, "failure", 15*time.Second, func(s Status) bool { return s.State == "failed" })
	if got.Error != "no direct path" {
		t.Fatalf("error %q", got.Error)
	}
}

// A STUN server on localhost that answers with what it sees, optionally a port off (a symmetric NAT).
func fakeSTUN(t *testing.T, portShift int) string {
	t.Helper()
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	go func() {
		buf := make([]byte, 1500)
		for {
			size, from, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			request := &stun.Message{Raw: append([]byte{}, buf[:size]...)}
			if request.Decode() != nil {
				continue
			}
			answer := stun.MustBuild(stun.NewTransactionIDSetter(request.TransactionID), stun.BindingSuccess,
				&stun.XORMappedAddress{IP: from.IP, Port: from.Port + portShift})
			_, _ = conn.WriteToUDP(answer.Raw, from)
		}
	}()
	return conn.LocalAddr().String()
}

func TestNATClassification(t *testing.T) {
	n, err := newBoundNet("")
	if err != nil {
		t.Fatal(err)
	}
	// Two servers on one IP count as one: the mapping can't be told.
	same := probeNAT(n, []string{fakeSTUN(t, 0), fakeSTUN(t, 0)})
	if same.Mapping != "none" || same.Answers[0] == "" || same.Answers[1] == "" {
		t.Fatalf("loopback: %+v", same)
	}
	result := NATResult{Answers: []string{"1.2.3.4:5000", "1.2.3.4:5000"}}
	classify(&result, map[string]bool{}, []string{"9.9.9.1", "9.9.9.2"})
	if result.Mapping != "independent" || result.Public != "1.2.3.4:5000" {
		t.Fatalf("cone: %+v", result)
	}
	result = NATResult{Answers: []string{"1.2.3.4:5000", "1.2.3.4:5007", ""}}
	classify(&result, map[string]bool{}, []string{"9.9.9.1", "9.9.9.2", "9.9.9.3"})
	if result.Mapping != "dependent" {
		t.Fatalf("symmetric: %+v", result)
	}
	result = NATResult{Answers: []string{"", "1.2.3.4:5000"}}
	classify(&result, map[string]bool{}, []string{"9.9.9.1", "9.9.9.2"})
	if result.Mapping != "unknown" {
		t.Fatalf("one answer: %+v", result)
	}
	result = NATResult{Answers: []string{"", ""}}
	classify(&result, map[string]bool{}, []string{"9.9.9.1", "9.9.9.2"})
	if result.Mapping != "blocked" {
		t.Fatalf("no answer: %+v", result)
	}
}

func TestPMPAnswer(t *testing.T) {
	ok := parsePMP([]byte{0, 128, 0, 0, 0, 0, 1, 0, 93, 184, 216, 34})
	if ok.External != "93.184.216.34" || ok.Error != "" {
		t.Fatalf("%+v", ok)
	}
	if pcp := parsePMP([]byte{2, 128, 0, 1}); pcp.Error != "PCP only" {
		t.Fatalf("%+v", pcp)
	}
	if refused := parsePMP([]byte{0, 128, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0}); refused.Error != "result 2" {
		t.Fatalf("%+v", refused)
	}
}

func TestCandidateTypes(t *testing.T) {
	sdp := "v=0\r\na=candidate:1 1 udp 2130706431 192.168.1.2 50000 typ host\r\n" +
		"a=candidate:2 1 udp 1694498815 93.1.2.3 50001 typ srflx raddr 0.0.0.0 rport 50001\r\n" +
		"a=candidate:3 1 udp 2130706431 192.168.1.3 50002 typ host\r\n"
	got := candidateTypes(sdp)
	if got["host"] != 2 || got["srflx"] != 1 {
		t.Fatalf("%v", got)
	}
}

// The real thing: this Mac's NAT and router (P2P_NET=1, needs the network).
func TestProbesOnThisNetwork(t *testing.T) {
	if os.Getenv("P2P_NET") != "1" {
		t.Skip("P2P_NET=1 to ask public STUN servers and the router")
	}
	nat := ProbeNAT(os.Getenv("P2P_IFACE"), nil)
	t.Logf("NAT: %+v", nat)
	router := ProbeRouter()
	data, _ := json.Marshal(router)
	t.Logf("router: %s", data)
}
