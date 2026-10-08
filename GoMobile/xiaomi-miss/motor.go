// Waiting Paws addition to go2rtc v1.9.14 pkg/xiaomi/miss, put in place by GoMobile/build.sh.
//
// Pan/tilt cameras turn with the MISS command 0x112 {"operation": N} (1 left, 2 right, 3 up, 4 down), the way Mi Home
// does it: one step per command, about a tenth of the frame. go2rtc declares cmdMotorReq but never sends it. The step
// goes over the session the stream already holds: many of these cameras take a single P2P session, and dialing a
// second one would drop the video. Upstream PR AlexxIT/go2rtc#2531 does the same (open as of v1.9.14).
package miss

import (
	"encoding/binary"
	"fmt"
)

// Motor moves the camera one step: operation 1 - left, 2 - right, 3 - up, 4 - down.
func (c *Client) Motor(operation int) error {
	data := binary.BigEndian.AppendUint32(nil, cmdMotorReq)
	data = fmt.Appendf(data, `{"operation":%d}`, operation)
	return c.WriteCommand(data)
}

// Motor sends a step over this producer's camera session (see Client.Motor).
func (p *Producer) Motor(operation int) error {
	return p.client.Motor(operation)
}
