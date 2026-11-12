//go:build !darwin

package p2p

import (
	"errors"
	"net"
)

func defaultGateway() (net.IP, error) { return nil, errors.New("no gateway lookup on this system") }
