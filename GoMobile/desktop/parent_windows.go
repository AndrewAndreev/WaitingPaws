package main

import (
	"errors"
	"fmt"

	"golang.org/x/sys/windows"
)

// exitWithParent opens the parent process and exits as soon as it is signalled (the process ended in any way:
// closed, crashed, killed). Holding the handle pins the process object, so a PID reused later can't be
// mistaken for the parent. No polling: the wait is a single blocked goroutine.
func exitWithParent(pid int) error {
	h, err := windows.OpenProcess(windows.SYNCHRONIZE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
		parentGone(pid) // no such process: it exited before we got here
	}
	if err != nil {
		return fmt.Errorf("watch parent process %d: %w", pid, err)
	}

	// Between the parent's exit and OpenProcess its PID may already belong to a new process.
	// The real parent was created before this one.
	var created, self, unused windows.Filetime
	if windows.GetProcessTimes(h, &created, &unused, &unused, &unused) == nil &&
		windows.GetProcessTimes(windows.CurrentProcess(), &self, &unused, &unused, &unused) == nil &&
		created.Nanoseconds() > self.Nanoseconds() {
		parentGone(pid)
	}

	go func() {
		_, _ = windows.WaitForSingleObject(h, windows.INFINITE)
		parentGone(pid)
	}()
	return nil
}
