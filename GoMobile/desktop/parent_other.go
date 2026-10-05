//go:build !windows

package main

import (
	"os"
	"syscall"
	"time"
)

// exitWithParent polls the parent once a second (only Windows is shipped; this keeps the package building
// elsewhere). A direct parent is watched through os.Getppid, which changes when the parent dies, so a reused
// PID can't fool it; any other process through kill(pid, 0).
func exitWithParent(pid int) error {
	direct := os.Getppid() == pid
	alive := func() bool {
		if direct {
			return os.Getppid() == pid
		}
		err := syscall.Kill(pid, 0)
		return err == nil || err == syscall.EPERM
	}
	if !alive() {
		parentGone(pid)
	}
	go func() {
		for range time.Tick(time.Second) {
			if !alive() {
				parentGone(pid)
			}
		}
	}()
	return nil
}
