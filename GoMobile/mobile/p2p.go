package mobile

import (
	"encoding/json"
	"fmt"

	"github.com/AlexxIT/go2rtc/pkg/p2p"
)

// P2PEvents receives a direct link's events (the app implements it; called on Go's goroutines).
type P2PEvents interface {
	// Signal: a message for the peer (an offer, an answer), for the apps' own link.
	Signal(message string)
	// State: the link's status as JSON (GoMobile/p2p Status), on every change and every answered ping.
	State(status string)
}

// P2PLink is one direct iPhone ↔ Mac link (GoMobile/p2p): a WebRTC data channel with pings, over public STUN, which
// also carries TCP streams to the Mac's services once the home network is gone.
type P2PLink struct {
	link *p2p.Link
}

// NewP2PLink prepares a link from its options (JSON, GoMobile/p2p Options).
func NewP2PLink(options string, events P2PEvents) (*P2PLink, error) {
	var opts p2p.Options
	if err := json.Unmarshal([]byte(options), &opts); err != nil {
		return nil, err
	}
	link, err := p2p.NewLink(opts, events)
	if err != nil {
		return nil, err
	}
	return &P2PLink{link: link}, nil
}

// Start (the offering side): gathers candidates, then signals the offer.
func (l *P2PLink) Start() error { return l.link.Start() }

// HandleSignal takes the peer's offer or answer.
func (l *P2PLink) HandleSignal(message string) error { return l.link.HandleSignal(message) }

// Restart (the offering side): a new session next to the current one, its offer over the data channel while that is
// open (no other link needed), taking over once it connects.
func (l *P2PLink) Restart() error { return l.link.Restart() }

// Forward (the offering side): listens on 127.0.0.1 for the peer's service ("sync", "go2rtc"); every connection made
// to that port goes over the link to the service (GoMobile/p2p tunnel.go). Returns the port, 0 if it could not listen.
func (l *P2PLink) Forward(service string) int {
	port, err := l.link.Forward(service, 0)
	if err != nil {
		fmt.Printf("p2p: forward %s: %v\n", service, err)
		return 0
	}
	return port
}

// Status is the link's status now (JSON).
func (l *P2PLink) Status() string { return l.link.StatusJSON() }

// Close ends the link (the peer is told over the data channel).
func (l *P2PLink) Close() { l.link.Close() }

// P2PProbeNAT asks public STUN servers from one socket (bound to iface, "" = the default route) how this side's NAT
// maps it; JSON (GoMobile/p2p NATResult). About 1.5 s.
func P2PProbeNAT(iface string) string {
	data, _ := json.Marshal(p2p.ProbeNAT(iface, nil))
	return string(data)
}

// P2PProbeRouter asks the home router (NAT-PMP, UPnP IGD) for its external address, without making any mapping;
// JSON (GoMobile/p2p RouterResult). About 2 s.
func P2PProbeRouter() string {
	data, _ := json.Marshal(p2p.ProbeRouter())
	return string(data)
}
