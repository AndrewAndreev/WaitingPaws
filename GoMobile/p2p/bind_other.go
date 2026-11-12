//go:build !darwin

package p2p

const canBind = false

func bindToInterface(uintptr, string, int) error { return nil }
