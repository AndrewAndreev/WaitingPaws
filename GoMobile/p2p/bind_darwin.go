//go:build darwin

package p2p

import (
	"strings"
	"syscall"
)

const canBind = true

// bindToInterface scopes a socket to one interface: the system then routes it that way whatever the default route
// is. A dual-stack socket ("udp" without an address) is IPv6, IPv4-mapped included.
func bindToInterface(fd uintptr, network string, index int) error {
	if index == 0 {
		return nil
	}
	if strings.HasSuffix(network, "4") {
		return syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_BOUND_IF, index)
	}
	if err := syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IPV6, syscall.IPV6_BOUND_IF, index); err != nil {
		// An IPv4 socket under a plain "udp" network.
		return syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_BOUND_IF, index)
	}
	return nil
}
