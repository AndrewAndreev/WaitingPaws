// Package p2p is the direct link between an iPhone and its Mac (an experiment): a WebRTC data channel (pion) whose
// ICE uses public STUN only, no TURN and no server of our own. The offer and the answer travel over the apps' own
// link (sync v2 on the home network); once the data channel is open, an ICE restart travels over the channel itself.
// A restart is "make before break": a new PeerConnection is set up next to the current one, with its offer and answer
// over the current data channel while that is open, and takes over once its own channel opens (pion's own ICE
// restart drops the current pair before the new offer could leave over it).
// It carries no video and no commands yet: pings with their round trip, to learn whether a direct path exists for a
// household's NAT and carrier.
//
// The iPhone makes two links to its Mac: "lan" over Wi-Fi as it is, and "out" with every socket bound to the
// cellular interface (Options.Interface), so that its path is the one the phone has away from home (the carrier's
// NAT ↔ the home router's NAT) while it is still at home and can signal over the LAN.
package p2p

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/webrtc/v4"
)

// Options of one link, as JSON from the app.
type Options struct {
	// "offer" (the iPhone starts the link) or "answer" (the Mac).
	Role string `json:"role"`
	// Which link of the pair: "lan" or "out".
	Label string `json:"label"`
	// STUN servers, "stun:host:port".
	STUN []string `json:"stun"`
	// Every socket is bound to this interface ("pdp_ip0": the iPhone's cellular; "en0": the Mac's LAN), so the
	// operating system sends it that way whatever its default route is (a VPN, Wi-Fi). Empty: the default route.
	Interface string `json:"interface"`
	// Host candidates only from interfaces whose name starts with one of these ("en", "bridge"); empty: any but
	// loopback, VPN tunnels and Apple's peer-to-peer ones.
	Interfaces []string `json:"interfaces"`
	// No host candidates with private addresses (10/8, 192.168/16, CGNAT 100.64/10, link-local, ULA): the "out"
	// link must not connect through the home network. Global IPv6 addresses stay (no NAT on that path).
	NoPrivateHost bool `json:"noPrivateHost"`
	// Loopback host candidates too (tests on one machine: its firewall may drop packets to its LAN address).
	Loopback bool `json:"loopback"`
	// Seconds between pings (2).
	PingInterval float64 `json:"pingInterval"`
	// Seconds the first connection may take before the link counts as failed (25).
	ConnectTimeout float64 `json:"connectTimeout"`
	// Seconds without any answer, once connected, before ICE gives the link up (600: an iPhone suspended in the
	// background for a few minutes may still find it alive when it is back).
	FailedTimeout float64 `json:"failedTimeout"`
}

// Events of a link for the app (called on Go's goroutines).
type Events interface {
	// A message for the peer, to send over the apps' link (an offer, an answer).
	Signal(message string)
	// The link's Status as JSON, on every change and every answered ping.
	State(status string)
}

// Signal is what the peers exchange: the whole offer or answer with every candidate in it (no trickle).
type Signal struct {
	Type string `json:"type"` // "offer", "answer"
	SDP  string `json:"sdp"`
	// 0 for the first offer, one more for every ICE restart.
	Gen int `json:"gen"`
	// How the sender's NAT maps ports, and the interface its sockets are bound to.
	NAT   *NATResult `json:"nat,omitempty"`
	Iface string     `json:"iface,omitempty"`
}

// Candidate is one end of the selected candidate pair.
type Candidate struct {
	Type     string `json:"type"` // host, srflx, prflx, relay
	Protocol string `json:"protocol"`
	Address  string `json:"address"`
	Port     int    `json:"port"`
}

// Status of a link, for the app.
type Status struct {
	Label string `json:"label"`
	Role  string `json:"role"`
	// new, gathering, connecting, connected, disconnected, failed, closed.
	State string `json:"state"`
	// When the state began (Unix ms).
	Since int64 `json:"since"`
	Gen   int   `json:"gen"`
	// The selected candidate pair.
	Local  *Candidate `json:"local,omitempty"`
	Remote *Candidate `json:"remote,omitempty"`
	// Round trip of the data channel's pings, ms: the last one, the smallest, a moving average.
	RTT    float64 `json:"rtt"`
	RTTMin float64 `json:"rttMin"`
	RTTAvg float64 `json:"rttAvg"`
	Pings  int     `json:"pings"`
	Pongs  int     `json:"pongs"`
	// The last pong (Unix ms), and when the link first connected.
	LastPong    int64 `json:"lastPong"`
	ConnectedAt int64 `json:"connectedAt"`
	// The candidates in this side's and the peer's description, by type.
	LocalTypes  map[string]int `json:"localTypes,omitempty"`
	RemoteTypes map[string]int `json:"remoteTypes,omitempty"`
	// This side's and the peer's NAT, and the interface the peer's sockets are bound to.
	NAT       *NATResult `json:"nat,omitempty"`
	PeerNAT   *NATResult `json:"peerNat,omitempty"`
	PeerIface string     `json:"peerIface,omitempty"`
	// Restarts that took over, and how the last restart's offer or answer went: "channel" (over the data channel
	// itself, no other link needed) or "app" (the apps' link).
	Restarts   int    `json:"restarts"`
	Restarting bool   `json:"restarting,omitempty"`
	SignalPath string `json:"signalPath,omitempty"`
	Error      string `json:"error,omitempty"`
}

// The data channel's messages.
type wire struct {
	T string  `json:"t"` // ping, pong, sig, bye
	N uint32  `json:"n,omitempty"`
	S *Signal `json:"s,omitempty"`
}

// Link is one direct link to the peer.
type Link struct {
	opts   Options
	events Events
	api    *webrtc.API
	bound  *boundNet

	mu sync.Mutex
	// The session in use, and the one a restart is setting up.
	cur, next *session
	status    Status
	closed    bool
	sent      map[uint32]time.Time
	seq       uint32
	stop      chan struct{}
	pinging   bool
}

// session is one PeerConnection with its data channel.
type session struct {
	gen int
	pc  *webrtc.PeerConnection
	dc  *webrtc.DataChannel
	// Its offer came over the data channel: the answer goes back the same way.
	viaChannel bool
	deadline   *time.Timer
}

func (s *session) open() bool {
	return s != nil && s.dc != nil && s.dc.ReadyState() == webrtc.DataChannelStateOpen
}

// NewLink prepares a link; nothing is sent before Start (offer) or the first HandleSignal (answer).
func NewLink(opts Options, events Events) (*Link, error) {
	if opts.Role != "offer" && opts.Role != "answer" {
		return nil, fmt.Errorf("p2p: role %q", opts.Role)
	}
	if opts.PingInterval <= 0 {
		opts.PingInterval = 2
	}
	if opts.ConnectTimeout <= 0 {
		opts.ConnectTimeout = 25
	}
	if opts.FailedTimeout <= 0 {
		opts.FailedTimeout = 600
	}
	bound, err := newBoundNet(opts.Interface)
	if err != nil {
		return nil, err
	}

	var se webrtc.SettingEngine
	se.SetNet(bound)
	se.SetICEMulticastDNSMode(ice.MulticastDNSModeDisabled) // iOS needs an entitlement for multicast
	se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4, webrtc.NetworkTypeUDP6})
	se.SetICETimeouts(5*time.Second, time.Duration(opts.FailedTimeout*float64(time.Second)), 2*time.Second)
	se.SetSTUNGatherTimeout(3 * time.Second)
	// Hole punching: the peer starts its checks only once it has our description, so keep asking a while longer.
	se.SetICEMaxBindingRequests(25)
	se.SetInterfaceFilter(func(name string) bool { return hostInterface(name, opts.Interfaces) })
	se.SetIncludeLoopbackCandidate(opts.Loopback)
	if opts.NoPrivateHost {
		se.SetIPFilter(func(ip net.IP) bool { return !isPrivate(ip) })
	}

	link := &Link{
		opts:   opts,
		events: events,
		api:    webrtc.NewAPI(webrtc.WithSettingEngine(se)),
		bound:  bound,
		sent:   map[uint32]time.Time{},
		stop:   make(chan struct{}),
	}
	link.status = Status{Label: opts.Label, Role: opts.Role, State: "new", Since: nowMS()}
	return link, nil
}

// Start (offerer): gathers, then signals the offer.
func (l *Link) Start() error {
	l.mu.Lock()
	if l.closed || l.cur != nil || l.opts.Role != "offer" {
		l.mu.Unlock()
		return errors.New("p2p: already started")
	}
	s, err := l.newSession(0, true)
	if err != nil {
		l.mu.Unlock()
		return l.fail(err)
	}
	l.cur = s
	l.setState("gathering")
	l.mu.Unlock()
	l.emit()
	go l.offer(s)
	return nil
}

// Restart (offerer): a new session next to the current one, its offer over the data channel while that is open (no
// other link needed, e.g. away from home), otherwise over the apps' link.
func (l *Link) Restart() error {
	l.mu.Lock()
	if l.closed || l.cur == nil || l.opts.Role != "offer" {
		l.mu.Unlock()
		return errors.New("p2p: nothing to restart")
	}
	if l.next != nil {
		l.mu.Unlock()
		return nil // one is already on its way
	}
	s, err := l.newSession(l.cur.gen+1, true)
	if err != nil {
		l.mu.Unlock()
		return err
	}
	l.next = s
	l.status.Restarting = true
	l.mu.Unlock()
	l.emit()
	go l.offer(s)
	return nil
}

// HandleSignal takes the peer's offer (answerer) or answer (offerer).
func (l *Link) HandleSignal(message string) error {
	var signal Signal
	if err := json.Unmarshal([]byte(message), &signal); err != nil {
		return fmt.Errorf("p2p: bad signal: %w", err)
	}
	return l.handle(&signal, false)
}

func (l *Link) handle(signal *Signal, viaChannel bool) error {
	switch signal.Type {
	case "offer":
		return l.handleOffer(signal, viaChannel)
	case "answer":
		return l.handleAnswer(signal)
	}
	return fmt.Errorf("p2p: signal %q", signal.Type)
}

func (l *Link) handleOffer(signal *Signal, viaChannel bool) error {
	l.mu.Lock()
	if l.closed || l.opts.Role != "answer" {
		l.mu.Unlock()
		return errors.New("p2p: not answering")
	}
	if newest := l.newestGen(); l.cur != nil && signal.Gen <= newest {
		l.mu.Unlock()
		return nil // a session this side already has
	}
	s, err := l.newSession(signal.Gen, false)
	if err != nil {
		l.mu.Unlock()
		return l.fail(err)
	}
	s.viaChannel = viaChannel
	first := l.cur == nil
	if first {
		l.cur = s
		l.setState("gathering")
	} else {
		l.replaceNext(s)
		l.status.Restarting = true
	}
	l.peerSaid(signal)
	l.mu.Unlock()
	l.emit()
	if err := s.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: signal.SDP}); err != nil {
		return l.sessionFailed(s, err)
	}
	go func() {
		answer, err := l.describe(s)
		if err != nil {
			_ = l.sessionFailed(s, err)
			return
		}
		l.described(s)
		l.send(answer, s.viaChannel)
	}()
	return nil
}

func (l *Link) handleAnswer(signal *Signal) error {
	l.mu.Lock()
	var s *session
	for _, candidate := range []*session{l.cur, l.next} {
		if candidate != nil && candidate.gen == signal.Gen {
			s = candidate
		}
	}
	if l.closed || l.opts.Role != "offer" || s == nil {
		l.mu.Unlock()
		return fmt.Errorf("p2p: an answer to no offer (gen %d)", signal.Gen)
	}
	l.peerSaid(signal)
	l.mu.Unlock()
	l.emit()
	if err := s.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: signal.SDP}); err != nil {
		return l.sessionFailed(s, err)
	}
	return nil
}

// Close ends the link and tells the peer over the data channel, if it is open.
func (l *Link) Close() {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	l.closed = true
	close(l.stop)
	sessions := []*session{l.cur, l.next}
	l.setState("closed")
	l.mu.Unlock()
	for _, s := range sessions {
		if s == nil {
			continue
		}
		if s.deadline != nil {
			s.deadline.Stop()
		}
		if s.open() {
			if data, err := json.Marshal(wire{T: "bye"}); err == nil {
				_ = s.dc.SendText(string(data))
				time.Sleep(50 * time.Millisecond)
			}
		}
		_ = s.pc.Close()
	}
	l.emit()
}

// StatusJSON is the link's Status now.
func (l *Link) StatusJSON() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.statusJSONLocked()
}

// MARK: - inside

// newSession: a PeerConnection (the offerer makes the data channel, the answerer gets it). Under l.mu.
func (l *Link) newSession(gen int, makeChannel bool) (*session, error) {
	var servers []webrtc.ICEServer
	if len(l.opts.STUN) > 0 {
		servers = []webrtc.ICEServer{{URLs: l.opts.STUN}}
	}
	pc, err := l.api.NewPeerConnection(webrtc.Configuration{ICEServers: servers})
	if err != nil {
		return nil, err
	}
	s := &session{gen: gen, pc: pc}
	pc.OnICEConnectionStateChange(func(state webrtc.ICEConnectionState) { l.iceChanged(s, state) })
	if sctp := pc.SCTP(); sctp != nil {
		sctp.Transport().ICETransport().OnSelectedCandidatePairChange(func(*webrtc.ICECandidatePair) { l.pairChanged(s) })
	}
	if makeChannel {
		dc, err := pc.CreateDataChannel("wp", nil)
		if err != nil {
			_ = pc.Close()
			return nil, err
		}
		l.attach(s, dc)
	} else {
		pc.OnDataChannel(func(dc *webrtc.DataChannel) {
			l.mu.Lock()
			l.attach(s, dc)
			l.mu.Unlock()
		})
	}
	return s, nil
}

func (l *Link) offer(s *session) {
	signal, err := l.describe(s)
	if err != nil {
		_ = l.sessionFailed(s, err)
		return
	}
	l.described(s)
	l.mu.Lock()
	// A restart's offer over the current channel while it is open.
	via := s != l.cur && l.cur.open() && l.status.State == "connected"
	l.mu.Unlock()
	l.send(signal, via)
}

// described: the session's description is ready to go; from now on it has ConnectTimeout to connect.
func (l *Link) described(s *session) {
	l.mu.Lock()
	if s == l.cur && l.status.ConnectedAt == 0 {
		l.setState("connecting")
	}
	if s.deadline != nil {
		s.deadline.Stop()
	}
	s.deadline = time.AfterFunc(time.Duration(l.opts.ConnectTimeout*float64(time.Second)), func() { l.timedOut(s) })
	l.mu.Unlock()
	l.emit()
}

// describe makes the session's offer or answer, waits for every candidate, and probes the NAT meanwhile.
func (l *Link) describe(s *session) (*Signal, error) {
	natDone := make(chan *NATResult, 1)
	go func() { natDone <- probeNATCached(l.bound, l.opts.STUN) }()

	var desc webrtc.SessionDescription
	var err error
	kind := "answer"
	if l.opts.Role == "offer" {
		kind = "offer"
		desc, err = s.pc.CreateOffer(nil)
	} else {
		desc, err = s.pc.CreateAnswer(nil)
	}
	if err != nil {
		return nil, err
	}
	gathered := webrtc.GatheringCompletePromise(s.pc)
	if err = s.pc.SetLocalDescription(desc); err != nil {
		return nil, err
	}
	select {
	case <-gathered:
	case <-time.After(8 * time.Second):
	case <-l.stop:
		return nil, errors.New("p2p: closed")
	}
	nat := <-natDone
	local := s.pc.LocalDescription()
	if local == nil {
		return nil, errors.New("p2p: no local description")
	}
	l.mu.Lock()
	l.status.NAT = nat
	l.status.LocalTypes = candidateTypes(local.SDP)
	l.mu.Unlock()
	return &Signal{Type: kind, SDP: local.SDP, Gen: s.gen, NAT: nat, Iface: l.opts.Interface}, nil
}

// send gives a signal to the peer: over the current data channel (viaChannel) or to the app for its link.
func (l *Link) send(signal *Signal, viaChannel bool) {
	if viaChannel {
		l.mu.Lock()
		cur := l.cur
		l.mu.Unlock()
		if data, err := json.Marshal(wire{T: "sig", S: signal}); err == nil && cur.open() && cur.dc.SendText(string(data)) == nil {
			l.mu.Lock()
			l.status.SignalPath = "channel"
			l.mu.Unlock()
			l.emit()
			return
		}
	}
	data, err := json.Marshal(signal)
	if err != nil {
		return
	}
	if signal.Gen > 0 {
		l.mu.Lock()
		l.status.SignalPath = "app"
		l.mu.Unlock()
	}
	l.events.Signal(string(data))
	l.emit()
}

// attach: the session's data channel. Under l.mu.
func (l *Link) attach(s *session, dc *webrtc.DataChannel) {
	s.dc = dc
	dc.OnOpen(func() { l.channelOpened(s) })
	dc.OnMessage(func(msg webrtc.DataChannelMessage) { l.received(s, msg.Data) })
	dc.OnClose(func() { l.channelClosed(s) })
}

func (l *Link) channelOpened(s *session) {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	if s.deadline != nil {
		s.deadline.Stop()
	}
	var old *session
	switch s {
	case l.cur:
	case l.next:
		// The restart's session takes over.
		old, l.cur, l.next = l.cur, s, nil
		l.status.Gen = s.gen
		l.status.Restarts++
		l.status.Restarting = false
		l.status.State = "" // whatever it was (disconnected, failed): connected again below
	default:
		l.mu.Unlock()
		return
	}
	if l.status.ConnectedAt == 0 {
		l.status.ConnectedAt = nowMS()
	}
	l.setState("connected")
	start := !l.pinging
	l.pinging = true
	l.mu.Unlock()
	if old != nil {
		fmt.Printf("%s p2p: %s: restart %d took over\n", clock(), l.opts.Label, s.gen)
		go func() {
			time.Sleep(time.Second) // its last pongs may still be on the way
			_ = old.pc.Close()
		}()
	}
	l.refreshPair()
	l.emit()
	if start {
		go l.pingLoop()
	}
}

func (l *Link) channelClosed(s *session) {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	switch s {
	case l.cur:
		if l.next != nil {
			l.mu.Unlock()
			return // the restart may still take over
		}
		l.setState("failed")
		if l.status.Error == "" {
			l.status.Error = "the channel closed"
		}
	case l.next:
		l.next = nil
		l.status.Restarting = false
	default:
		l.mu.Unlock()
		return
	}
	l.mu.Unlock()
	l.emit()
}

func (l *Link) received(s *session, data []byte) {
	var msg wire
	if json.Unmarshal(data, &msg) != nil {
		return
	}
	switch msg.T {
	case "ping":
		if reply, err := json.Marshal(wire{T: "pong", N: msg.N}); err == nil && s.open() {
			_ = s.dc.SendText(string(reply))
		}
	case "pong":
		l.mu.Lock()
		sent, ok := l.sent[msg.N]
		if !ok {
			l.mu.Unlock()
			return
		}
		delete(l.sent, msg.N)
		rtt := float64(time.Since(sent).Microseconds()) / 1000
		st := &l.status
		st.Pongs++
		st.RTT = rtt
		st.LastPong = nowMS()
		if st.RTTMin == 0 || rtt < st.RTTMin {
			st.RTTMin = rtt
		}
		if st.RTTAvg == 0 {
			st.RTTAvg = rtt
		} else {
			st.RTTAvg = st.RTTAvg*0.8 + rtt*0.2
		}
		if st.State == "disconnected" && s == l.cur {
			l.setState("connected")
		}
		l.mu.Unlock()
		l.emit()
	case "sig":
		if msg.S != nil {
			if err := l.handle(msg.S, true); err != nil {
				fmt.Printf("%s p2p: %s: a signal over the channel: %v\n", clock(), l.opts.Label, err)
			}
		}
	case "bye":
		go func() {
			l.mu.Lock()
			l.status.Error = "the peer closed the link"
			l.mu.Unlock()
			l.Close()
		}()
	}
}

// pingLoop pings over the current session's channel every PingInterval.
func (l *Link) pingLoop() {
	ticker := time.NewTicker(time.Duration(l.opts.PingInterval * float64(time.Second)))
	defer ticker.Stop()
	for {
		l.mu.Lock()
		cur := l.cur
		var n uint32
		if cur.open() {
			l.seq++
			n = l.seq
			l.sent[n] = time.Now()
			// Pings lost while the link was down are not waited for any more.
			for k, at := range l.sent {
				if time.Since(at) > 30*time.Second {
					delete(l.sent, k)
				}
			}
			l.status.Pings++
		}
		l.mu.Unlock()
		if n != 0 {
			if data, err := json.Marshal(wire{T: "ping", N: n}); err == nil {
				_ = cur.dc.SendText(string(data))
			}
		}
		select {
		case <-l.stop:
			return
		case <-ticker.C:
		}
	}
}

func (l *Link) iceChanged(s *session, state webrtc.ICEConnectionState) {
	l.mu.Lock()
	if l.closed || (s != l.cur && s != l.next) {
		l.mu.Unlock()
		return
	}
	which := "current"
	if s == l.next {
		which = "restart"
	}
	if s == l.cur {
		switch state {
		case webrtc.ICEConnectionStateDisconnected:
			if l.status.State == "connected" {
				l.setState("disconnected")
			}
		case webrtc.ICEConnectionStateConnected, webrtc.ICEConnectionStateCompleted:
			if l.status.State == "disconnected" {
				l.setState("connected")
			}
		case webrtc.ICEConnectionStateFailed:
			if l.next == nil {
				l.setState("failed")
				if l.status.Error == "" {
					l.status.Error = "ICE failed"
				}
			}
		}
	} else if state == webrtc.ICEConnectionStateFailed {
		l.next = nil
		l.status.Restarting = false
		go func() { _ = s.pc.Close() }()
	}
	l.mu.Unlock()
	fmt.Printf("%s p2p: %s: ICE %s (%s, gen %d)\n", clock(), l.opts.Label, state, which, s.gen)
	if state == webrtc.ICEConnectionStateConnected {
		l.refreshPair()
	}
	l.emit()
}

func (l *Link) pairChanged(s *session) {
	l.mu.Lock()
	cur := s == l.cur
	l.mu.Unlock()
	if !cur {
		return
	}
	l.refreshPair()
	l.mu.Lock()
	local, remote := l.status.Local, l.status.Remote
	l.mu.Unlock()
	if local != nil && remote != nil {
		fmt.Printf("%s p2p: %s: pair %s %s:%d ↔ %s %s:%d\n", clock(), l.opts.Label,
			local.Type, local.Address, local.Port, remote.Type, remote.Address, remote.Port)
	}
	l.emit()
}

// refreshPair reads the current session's selected candidate pair (pion's own locks, so not under ours).
func (l *Link) refreshPair() {
	l.mu.Lock()
	cur := l.cur
	l.mu.Unlock()
	if cur == nil {
		return
	}
	sctp := cur.pc.SCTP()
	if sctp == nil {
		return
	}
	pair, err := sctp.Transport().ICETransport().GetSelectedCandidatePair()
	if err != nil || pair == nil || pair.Local == nil || pair.Remote == nil {
		return
	}
	l.mu.Lock()
	if l.cur == cur {
		l.status.Local = candidate(pair.Local)
		l.status.Remote = candidate(pair.Remote)
	}
	l.mu.Unlock()
}

// timedOut: the session has not connected ConnectTimeout after its description went out (ICE itself would keep
// checking for FailedTimeout, kept long for the background). The first one fails the link; a restart's is dropped.
func (l *Link) timedOut(s *session) {
	l.mu.Lock()
	if l.closed || s.open() {
		l.mu.Unlock()
		return
	}
	switch s {
	case l.cur:
		if l.status.ConnectedAt != 0 {
			l.mu.Unlock()
			return
		}
		l.setState("failed")
		l.status.Error = "no direct path"
	case l.next:
		l.next = nil
		l.status.Restarting = false
		l.status.Error = "restart: no direct path"
	default:
		l.mu.Unlock()
		return
	}
	l.mu.Unlock()
	fmt.Printf("%s p2p: %s: no direct path in %.0f s (gen %d)\n", clock(), l.opts.Label, l.opts.ConnectTimeout, s.gen)
	l.emit()
	_ = s.pc.Close()
}

// sessionFailed: an error setting up a session: the link fails if it was the first one, a restart is dropped.
func (l *Link) sessionFailed(s *session, err error) error {
	l.mu.Lock()
	if s == l.next {
		l.next = nil
		l.status.Restarting = false
		l.status.Error = "restart: " + err.Error()
		l.mu.Unlock()
		fmt.Printf("%s p2p: %s: restart: %v\n", clock(), l.opts.Label, err)
		_ = s.pc.Close()
		l.emit()
		return err
	}
	l.mu.Unlock()
	return l.fail(err)
}

// replaceNext: a newer restart replaces one still being set up. Under l.mu.
func (l *Link) replaceNext(s *session) {
	if old := l.next; old != nil {
		if old.deadline != nil {
			old.deadline.Stop()
		}
		go func() { _ = old.pc.Close() }()
	}
	l.next = s
}

// peerSaid keeps what the peer's signal tells about it. Under l.mu.
func (l *Link) peerSaid(signal *Signal) {
	if signal.NAT != nil {
		l.status.PeerNAT = signal.NAT
	}
	l.status.PeerIface = signal.Iface
	l.status.RemoteTypes = candidateTypes(signal.SDP)
}

// newestGen: the newest session this side has. Under l.mu.
func (l *Link) newestGen() int {
	gen := -1
	for _, s := range []*session{l.cur, l.next} {
		if s != nil && s.gen > gen {
			gen = s.gen
		}
	}
	return gen
}

func (l *Link) fail(err error) error {
	l.mu.Lock()
	l.setState("failed")
	l.status.Error = err.Error()
	l.mu.Unlock()
	fmt.Printf("%s p2p: %s: %v\n", clock(), l.opts.Label, err)
	l.emit()
	return err
}

// setState. Under l.mu. A failed link only closes; a restart's takeover clears the state first.
func (l *Link) setState(state string) {
	if l.status.State == state {
		return
	}
	if l.status.State == "closed" || (l.status.State == "failed" && state != "closed") {
		return
	}
	l.status.State = state
	l.status.Since = nowMS()
}

func (l *Link) statusJSONLocked() string {
	data, _ := json.Marshal(l.status)
	return string(data)
}

func (l *Link) emit() {
	l.mu.Lock()
	status := l.statusJSONLocked()
	l.mu.Unlock()
	l.events.State(status)
}

func candidate(c *webrtc.ICECandidate) *Candidate {
	return &Candidate{Type: c.Typ.String(), Protocol: c.Protocol.String(), Address: c.Address, Port: int(c.Port)}
}

// candidateTypes counts the candidates of a description by type ("host": 2, "srflx": 1).
func candidateTypes(sdp string) map[string]int {
	types := map[string]int{}
	for _, line := range strings.Split(sdp, "\n") {
		if !strings.HasPrefix(line, "a=candidate:") {
			continue
		}
		fields := strings.Fields(line)
		for i := 0; i+1 < len(fields); i++ {
			if fields[i] == "typ" {
				types[fields[i+1]]++
				break
			}
		}
	}
	return types
}

// hostInterface: may host candidates come from this interface?
func hostInterface(name string, prefixes []string) bool {
	if len(prefixes) > 0 {
		for _, prefix := range prefixes {
			if strings.HasPrefix(name, prefix) {
				return true
			}
		}
		return false
	}
	for _, skip := range []string{"lo", "utun", "ipsec", "ppp", "awdl", "llw", "anpi", "gif", "stf", "ap"} {
		if strings.HasPrefix(name, skip) {
			return false
		}
	}
	return true
}

var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// isPrivate: not reachable from the internet as it is.
func isPrivate(ip net.IP) bool {
	return ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || cgnat.Contains(ip)
}

func nowMS() int64 { return time.Now().UnixMilli() }

func clock() string { return time.Now().Format("15:04:05") }
