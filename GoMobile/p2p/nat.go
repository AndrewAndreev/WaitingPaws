package p2p

import (
	"net"
	"strings"
	"sync"
	"time"

	"github.com/pion/stun/v3"
)

// NATResult: how this side's NAT maps one socket's port toward different STUN servers. With the same public
// address for every server ("independent", a cone NAT) hole punching usually works; with a new port per server
// ("dependent", a symmetric NAT — common with carriers' CGNAT) it works only if the other side's NAT is lenient,
// and a relay (TURN) is the reliable way.
type NATResult struct {
	// independent, dependent, none (a public address, no NAT), unknown (fewer than two servers answered),
	// blocked (no server answered: UDP to STUN is closed, or no network).
	Mapping string `json:"mapping"`
	// The address the first server saw, ip:port.
	Public string `json:"public,omitempty"`
	// Per server, in Servers' order: the address it saw, "" without an answer.
	Answers []string `json:"answers"`
	Servers []string `json:"servers"`
	Iface   string   `json:"iface,omitempty"`
	Error   string   `json:"error,omitempty"`
	// How long the probe took, ms.
	Took int `json:"took"`
}

// The servers the NAT probe asks (two Google addresses, so that two answers come even if Cloudflare's is blocked).
var probeServers = []string{"stun.cloudflare.com:3478", "stun.l.google.com:19302", "stun1.l.google.com:19302"}

// ProbeNAT asks STUN servers from one UDP socket (bound to iface, if given) what address they see.
func ProbeNAT(iface string, servers []string) NATResult {
	n, err := newBoundNet(iface)
	if err != nil {
		return NATResult{Mapping: "blocked", Iface: iface, Error: err.Error()}
	}
	if len(servers) == 0 {
		servers = probeServers
	}
	return probeNAT(n, servers)
}

var natCache struct {
	sync.Mutex
	at     map[string]time.Time
	result map[string]*NATResult
}

// probeNATCached: two links made together (the Mac answers "lan" and "out" at once) probe once.
func probeNATCached(n *boundNet, stunURLs []string) *NATResult {
	natCache.Lock()
	if at, ok := natCache.at[n.name]; ok && time.Since(at) < 30*time.Second {
		result := natCache.result[n.name]
		natCache.Unlock()
		return result
	}
	natCache.Unlock()
	servers := probeServers
	for _, url := range stunURLs {
		if host := strings.TrimPrefix(url, "stun:"); host != url && !contains(servers, host) {
			servers = append(append([]string{}, servers...), host)
		}
	}
	result := probeNAT(n, servers)
	natCache.Lock()
	if natCache.at == nil {
		natCache.at = map[string]time.Time{}
		natCache.result = map[string]*NATResult{}
	}
	natCache.at[n.name] = time.Now()
	natCache.result[n.name] = &result
	natCache.Unlock()
	return &result
}

func probeNAT(n *boundNet, servers []string) NATResult {
	start := time.Now()
	result := NATResult{Servers: servers, Answers: make([]string, len(servers)), Iface: n.name}
	defer func() { result.Took = int(time.Since(start).Milliseconds()) }()

	conn, err := n.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero})
	if err != nil {
		result.Mapping, result.Error = "blocked", err.Error()
		return result
	}
	defer conn.Close()

	type query struct {
		addr *net.UDPAddr
		msg  *stun.Message
	}
	queries := make([]*query, len(servers))
	byID := map[[stun.TransactionIDSize]byte]int{}
	for i, server := range servers {
		addr, err := n.ResolveUDPAddr("udp4", server)
		if err != nil {
			continue
		}
		msg := stun.MustBuild(stun.TransactionID, stun.BindingRequest)
		queries[i] = &query{addr: addr, msg: msg}
		byID[msg.TransactionID] = i
	}

	// Asked at once, again after 0.4 s and 0.9 s if still silent; answers are taken for 1.5 s.
	resend := func() {
		for i, q := range queries {
			if q != nil && result.Answers[i] == "" {
				_, _ = conn.WriteTo(q.msg.Raw, q.addr)
			}
		}
	}
	resend()
	deadline := start.Add(1500 * time.Millisecond)
	next := []time.Time{start.Add(400 * time.Millisecond), start.Add(900 * time.Millisecond)}
	buf := make([]byte, 1500)
	for time.Now().Before(deadline) && answered(result.Answers) < countQueries(queries) {
		wait := deadline
		if len(next) > 0 && next[0].Before(wait) {
			wait = next[0]
		}
		_ = conn.SetReadDeadline(wait)
		size, _, err := conn.ReadFrom(buf)
		if err != nil {
			if len(next) > 0 && !time.Now().Before(next[0]) {
				next = next[1:]
				resend()
			}
			continue
		}
		msg := &stun.Message{Raw: append([]byte{}, buf[:size]...)}
		if msg.Decode() != nil {
			continue
		}
		i, ok := byID[msg.TransactionID]
		if !ok {
			continue
		}
		var xor stun.XORMappedAddress
		if xor.GetFrom(msg) != nil {
			continue
		}
		result.Answers[i] = (&net.UDPAddr{IP: xor.IP, Port: xor.Port}).String()
	}
	serverIPs := make([]string, len(queries))
	for i, q := range queries {
		if q != nil {
			serverIPs[i] = q.addr.IP.String()
		}
	}
	classify(&result, n.localIPs(), serverIPs)
	return result
}

// classify decides the mapping from the answers (serverIPs: each server's address, to compare different hosts only).
func classify(result *NATResult, local map[string]bool, serverIPs []string) {
	seen := map[string]string{} // server IP → mapped address
	for i, answer := range result.Answers {
		if answer == "" {
			continue
		}
		if result.Public == "" {
			result.Public = answer
		}
		if i < len(serverIPs) && serverIPs[i] != "" {
			seen[serverIPs[i]] = answer
		}
	}
	switch {
	case result.Public == "":
		result.Mapping = "blocked"
	case local[hostOf(result.Public)]:
		result.Mapping = "none"
	case len(seen) < 2:
		result.Mapping = "unknown"
	default:
		result.Mapping = "independent"
		for _, mapped := range seen {
			if mapped != result.Public {
				result.Mapping = "dependent"
			}
		}
	}
}

func answered(answers []string) int {
	count := 0
	for _, answer := range answers {
		if answer != "" {
			count++
		}
	}
	return count
}

func countQueries[T any](queries []*T) int {
	count := 0
	for _, q := range queries {
		if q != nil {
			count++
		}
	}
	return count
}

func hostOf(address string) string {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return address
	}
	return host
}

func contains(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}
