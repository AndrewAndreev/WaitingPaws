package p2p

import (
	"context"
	"fmt"
	"net"
	"syscall"

	"github.com/pion/transport/v4"
	"github.com/pion/transport/v4/stdnet"
)

// boundNet is pion's network with every UDP socket bound to one interface (IP_BOUND_IF on Apple's systems): an
// iPhone on Wi-Fi can then gather and connect over its cellular interface, exactly as it would away from home. It
// also lists only that interface for host candidates. Without an interface it is the standard network.
type boundNet struct {
	*stdnet.Net
	name  string
	index int
}

func newBoundNet(name string) (*boundNet, error) {
	std, err := stdnet.NewNet()
	if err != nil {
		return nil, err
	}
	n := &boundNet{Net: std, name: name}
	if name == "" {
		return n, nil
	}
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return nil, fmt.Errorf("p2p: no interface %s: %w", name, err)
	}
	if !canBind {
		return nil, fmt.Errorf("p2p: binding to an interface is not supported here")
	}
	n.index = iface.Index
	return n, nil
}

func (n *boundNet) Interfaces() ([]*transport.Interface, error) {
	all, err := n.Net.Interfaces()
	if err != nil || n.name == "" {
		return all, err
	}
	var only []*transport.Interface
	for _, iface := range all {
		if iface.Name == n.name {
			only = append(only, iface)
		}
	}
	return only, nil
}

func (n *boundNet) config() *net.ListenConfig {
	return &net.ListenConfig{Control: func(network, _ string, c syscall.RawConn) error {
		var err error
		if controlErr := c.Control(func(fd uintptr) { err = bindToInterface(fd, network, n.index) }); controlErr != nil {
			return controlErr
		}
		return err
	}}
}

func (n *boundNet) ListenPacket(network string, address string) (net.PacketConn, error) {
	if n.name == "" {
		return n.Net.ListenPacket(network, address)
	}
	return n.config().ListenPacket(context.Background(), network, address)
}

func (n *boundNet) ListenUDP(network string, locAddr *net.UDPAddr) (transport.UDPConn, error) {
	if n.name == "" {
		return n.Net.ListenUDP(network, locAddr)
	}
	address := ""
	if locAddr != nil {
		address = locAddr.String()
	}
	conn, err := n.config().ListenPacket(context.Background(), network, address)
	if err != nil {
		return nil, err
	}
	udp, ok := conn.(*net.UDPConn)
	if !ok {
		_ = conn.Close()
		return nil, fmt.Errorf("p2p: %T is not a UDP socket", conn)
	}
	return udp, nil
}

// The interface's own addresses (to tell "no NAT" when a STUN server sees one of them).
func (n *boundNet) localIPs() map[string]bool {
	ips := map[string]bool{}
	ifaces, err := n.Interfaces()
	if err != nil {
		return ips
	}
	for _, iface := range ifaces {
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			if ipNet, ok := addr.(*net.IPNet); ok {
				ips[ipNet.IP.String()] = true
			}
		}
	}
	return ips
}
