package powerui

/*
#cgo CFLAGS: -x objective-c -mmacosx-version-min=13.0
#cgo LDFLAGS: -framework Foundation
#include <stdlib.h>
int watt_native_charge(int write, int value, int *limit, int *enabled, int *limits, int *count, char **error);
*/
import "C"

import (
	"errors"
	"time"
	"unsafe"
)

type nativeBackend struct{}

// New probes support read-only. It never applies the saved WattNook limit.
func New() (*Controller, error) {
	c := newController(nativeBackend{}, 3*time.Second)
	if _, err := c.Read(); err != nil {
		return nil, err
	}
	return c, nil
}

func nativeCall(write bool, value int) (State, error) {
	var limit, enabled, count C.int
	var limits [21]C.int
	var message *C.char
	w := C.int(0)
	if write {
		w = 1
	}
	ok := C.watt_native_charge(w, C.int(value), &limit, &enabled, &limits[0], &count, &message)
	if message != nil {
		defer C.free(unsafe.Pointer(message))
	}
	if ok == 0 {
		if message != nil {
			return State{}, errors.New(C.GoString(message))
		}
		return State{}, errors.New("Apple native charge control unavailable")
	}
	s := State{Limit: int(limit), Enabled: enabled != 0}
	for i := 0; i < int(count) && i < len(limits); i++ {
		s.Limits = append(s.Limits, int(limits[i]))
	}
	return s, nil
}
func (nativeBackend) Read() (State, error) { return nativeCall(false, 0) }
func (nativeBackend) Set(v int) error      { _, err := nativeCall(true, v); return err }
