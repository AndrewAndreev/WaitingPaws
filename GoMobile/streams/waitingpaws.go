package streams

// Waiting Paws addition, copied into go2rtc's internal/streams by GoMobile/build.sh.

import "github.com/AlexxIT/go2rtc/pkg/core"

// Conns returns the connected sources of the stream, so a module can reach a source's own control channel (a camera's
// motor) over the session that is already open. A source that is dialing right now holds its lock for seconds and is
// skipped rather than waited for.
func (s *Stream) Conns() []core.Producer {
	s.mu.Lock()
	defer s.mu.Unlock()
	conns := make([]core.Producer, 0, len(s.producers))
	for _, prod := range s.producers {
		if !prod.mu.TryLock() {
			continue
		}
		if prod.conn != nil {
			conns = append(conns, prod.conn)
		}
		prod.mu.Unlock()
	}
	return conns
}
