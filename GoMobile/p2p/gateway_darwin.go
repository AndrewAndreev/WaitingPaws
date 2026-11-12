//go:build darwin

package p2p

import (
	"errors"
	"net"
	"strings"
	"syscall"

	"golang.org/x/net/route"
)

// defaultGateway: the IPv4 default route's gateway, a LAN interface's (en*, bridge*) before a VPN tunnel's.
func defaultGateway() (net.IP, error) {
	rib, err := route.FetchRIB(syscall.AF_INET, route.RIBTypeRoute, 0)
	if err != nil {
		return nil, err
	}
	messages, err := route.ParseRIB(route.RIBTypeRoute, rib)
	if err != nil {
		return nil, err
	}
	var lan, other net.IP
	for _, message := range messages {
		rm, ok := message.(*route.RouteMessage)
		if !ok || rm.Flags&syscall.RTF_GATEWAY == 0 || rm.Flags&syscall.RTF_UP == 0 || len(rm.Addrs) <= syscall.RTAX_GATEWAY {
			continue
		}
		dst, ok := rm.Addrs[syscall.RTAX_DST].(*route.Inet4Addr)
		if !ok || dst.IP != [4]byte{} {
			continue
		}
		if len(rm.Addrs) > syscall.RTAX_NETMASK {
			if mask, ok := rm.Addrs[syscall.RTAX_NETMASK].(*route.Inet4Addr); ok && mask.IP != [4]byte{} {
				continue
			}
		}
		gw, ok := rm.Addrs[syscall.RTAX_GATEWAY].(*route.Inet4Addr)
		if !ok {
			continue
		}
		ip := net.IPv4(gw.IP[0], gw.IP[1], gw.IP[2], gw.IP[3])
		name := ""
		if iface, err := net.InterfaceByIndex(rm.Index); err == nil {
			name = iface.Name
		}
		if strings.HasPrefix(name, "en") || strings.HasPrefix(name, "bridge") {
			if lan == nil {
				lan = ip
			}
		} else if other == nil {
			other = ip
		}
	}
	if lan != nil {
		return lan, nil
	}
	if other != nil {
		return other, nil
	}
	return nil, errors.New("no default gateway")
}
