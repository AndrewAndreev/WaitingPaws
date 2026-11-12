package p2p

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// RouterResult: can the home router give the Mac a stable address from the internet (a port mapping), so that an
// iPhone away from home could reach it again without any server? Only read: the external address is asked for,
// no mapping is made.
type RouterResult struct {
	Gateway string      `json:"gateway,omitempty"`
	PMP     *PMPResult  `json:"pmp,omitempty"`
	UPnP    *UPnPResult `json:"upnp,omitempty"`
	Error   string      `json:"error,omitempty"`
	Took    int         `json:"took"`
}

// PMPResult: NAT-PMP (RFC 6886; PCP routers answer it with "unsupported version").
type PMPResult struct {
	External string `json:"external,omitempty"`
	// "", or why there is no answer: "no answer", "PCP only", "result N".
	Error string `json:"error,omitempty"`
}

// UPnPResult: UPnP Internet Gateway Device.
type UPnPResult struct {
	Device   string `json:"device,omitempty"`
	Service  string `json:"service,omitempty"`
	External string `json:"external,omitempty"`
	Error    string `json:"error,omitempty"`
}

// ProbeRouter asks the default gateway over NAT-PMP and UPnP IGD for its external address (about 2 s).
func ProbeRouter() RouterResult {
	start := time.Now()
	var result RouterResult
	gateway, err := defaultGateway()
	if err != nil {
		result.Error = err.Error()
	} else {
		result.Gateway = gateway.String()
	}
	var wg sync.WaitGroup
	if gateway != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			result.PMP = probePMP(&net.UDPAddr{IP: gateway, Port: 5351})
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		result.UPnP = probeUPnP(gateway)
	}()
	wg.Wait()
	result.Took = int(time.Since(start).Milliseconds())
	return result
}

func probePMP(gateway *net.UDPAddr) *PMPResult {
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return &PMPResult{Error: err.Error()}
	}
	defer conn.Close()
	request := []byte{0, 0} // version 0, opcode 0: the external address
	buf := make([]byte, 64)
	for _, wait := range []time.Duration{250 * time.Millisecond, 500 * time.Millisecond, time.Second} {
		if _, err := conn.WriteToUDP(request, gateway); err != nil {
			return &PMPResult{Error: err.Error()}
		}
		_ = conn.SetReadDeadline(time.Now().Add(wait))
		for {
			size, from, err := conn.ReadFromUDP(buf)
			if err != nil {
				break
			}
			if !from.IP.Equal(gateway.IP) || size < 4 {
				continue
			}
			return parsePMP(buf[:size])
		}
	}
	return &PMPResult{Error: "no answer"}
}

func parsePMP(answer []byte) *PMPResult {
	if len(answer) < 4 || answer[1] != 128 {
		return &PMPResult{Error: fmt.Sprintf("unexpected answer % x", answer)}
	}
	code := binary.BigEndian.Uint16(answer[2:4])
	switch {
	case answer[0] != 0 || code == 1:
		return &PMPResult{Error: "PCP only"}
	case code != 0:
		return &PMPResult{Error: fmt.Sprintf("result %d", code)}
	case len(answer) < 12:
		return &PMPResult{Error: "short answer"}
	}
	return &PMPResult{External: net.IP(answer[8:12]).String()}
}

func probeUPnP(gateway net.IP) *UPnPResult {
	locations := ssdpSearch(1500*time.Millisecond, gateway)
	if len(locations) == 0 {
		return &UPnPResult{Error: "no answer"}
	}
	var last error
	for _, location := range locations {
		result, err := upnpExternal(location)
		if err == nil {
			return result
		}
		last = err
	}
	return &UPnPResult{Error: last.Error()}
}

// ssdpSearch finds Internet Gateway Devices on the network; the gateway's own first.
func ssdpSearch(wait time.Duration, gateway net.IP) []string {
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return nil
	}
	defer conn.Close()
	group := &net.UDPAddr{IP: net.IPv4(239, 255, 255, 250), Port: 1900}
	for _, target := range []string{"urn:schemas-upnp-org:device:InternetGatewayDevice:1",
		"urn:schemas-upnp-org:device:InternetGatewayDevice:2"} {
		request := "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: " +
			target + "\r\n\r\n"
		_, _ = conn.WriteToUDP([]byte(request), group)
	}
	_ = conn.SetReadDeadline(time.Now().Add(wait))
	var first, others []string
	buf := make([]byte, 2048)
	for {
		size, from, err := conn.ReadFromUDP(buf)
		if err != nil {
			break
		}
		response, err := http.ReadResponse(bufio.NewReader(bytes.NewReader(buf[:size])), nil)
		if err != nil {
			continue
		}
		location := response.Header.Get("Location")
		if location == "" || contains(first, location) || contains(others, location) {
			continue
		}
		if gateway != nil && from.IP.Equal(gateway) {
			first = append(first, location)
		} else {
			others = append(others, location)
		}
	}
	return append(first, others...)
}

type upnpService struct {
	Type    string `xml:"serviceType"`
	Control string `xml:"controlURL"`
}

type upnpDevice struct {
	Name     string        `xml:"friendlyName"`
	Model    string        `xml:"modelName"`
	Services []upnpService `xml:"serviceList>service"`
	Devices  []upnpDevice  `xml:"deviceList>device"`
}

type upnpRoot struct {
	Base   string     `xml:"URLBase"`
	Device upnpDevice `xml:"device"`
}

func upnpExternal(location string) (*UPnPResult, error) {
	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Get(location)
	if err != nil {
		return nil, err
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	_ = response.Body.Close()
	if err != nil {
		return nil, err
	}
	var root upnpRoot
	if err := xml.Unmarshal(body, &root); err != nil {
		return nil, err
	}
	device, service := findWAN(root.Device)
	if service == nil {
		return nil, errors.New("no WAN connection service")
	}
	base := location
	if root.Base != "" {
		base = root.Base
	}
	baseURL, err := url.Parse(base)
	if err != nil {
		return nil, err
	}
	control, err := baseURL.Parse(service.Control)
	if err != nil {
		return nil, err
	}
	result := &UPnPResult{Device: strings.TrimSpace(device.Name + " " + device.Model), Service: service.Type}
	soap := `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ` +
		`s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetExternalIPAddress xmlns:u="` +
		service.Type + `"></u:GetExternalIPAddress></s:Body></s:Envelope>`
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, control.String(), strings.NewReader(soap))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
	request.Header.Set("SOAPAction", `"`+service.Type+`#GetExternalIPAddress"`)
	answer, err := client.Do(request)
	if err != nil {
		result.Error = err.Error()
		return result, nil
	}
	body, _ = io.ReadAll(io.LimitReader(answer.Body, 1<<16))
	_ = answer.Body.Close()
	var envelope struct {
		Address string `xml:"Body>GetExternalIPAddressResponse>NewExternalIPAddress"`
	}
	if answer.StatusCode != http.StatusOK || xml.Unmarshal(body, &envelope) != nil || envelope.Address == "" {
		result.Error = fmt.Sprintf("GetExternalIPAddress: HTTP %d", answer.StatusCode)
		return result, nil
	}
	result.External = strings.TrimSpace(envelope.Address)
	return result, nil
}

func findWAN(device upnpDevice) (upnpDevice, *upnpService) {
	for i, service := range device.Services {
		if strings.Contains(service.Type, "WANIPConnection") || strings.Contains(service.Type, "WANPPPConnection") {
			return device, &device.Services[i]
		}
	}
	for _, child := range device.Devices {
		if found, service := findWAN(child); service != nil {
			if found.Name == "" {
				found = device
			}
			return found, service
		}
	}
	return device, nil
}
