package chargehold

/*
#cgo CFLAGS: -x objective-c -mmacosx-version-min=13.0
#cgo LDFLAGS: -framework Foundation
#include <stdlib.h>
int wattnook_charge_hold_preferences(int operation, int target, void *input, int inputSize, void **output, int *outputSize, int *readLimit, char **message);
*/
import "C"

import (
	"errors"
	"unsafe"
)

// SystemPreferences writes the topoff-protection domain. The daemon runs as
// root, so CurrentUser is root's preferences, matching AlDente's helper.
type SystemPreferences struct{}

func preferences(operation, target int, snapshot []byte) ([]byte, int, error) {
	var input unsafe.Pointer
	if len(snapshot) > 0 {
		input = C.CBytes(snapshot)
		defer C.free(input)
	}
	var output unsafe.Pointer
	var size, limit C.int
	var message *C.char
	ok := C.wattnook_charge_hold_preferences(C.int(operation), C.int(target), input, C.int(len(snapshot)), &output, &size, &limit, &message)
	if output != nil {
		defer C.free(output)
	}
	if message != nil {
		defer C.free(unsafe.Pointer(message))
	}
	if ok == 0 {
		if message != nil {
			return nil, 0, errors.New(C.GoString(message))
		}
		return nil, 0, errors.New("charging preferences operation failed")
	}
	return C.GoBytes(output, size), int(limit), nil
}

func (SystemPreferences) Snapshot() ([]byte, int, error) { return preferences(0, 0, nil) }

func (SystemPreferences) Hold(target int) error {
	_, _, err := preferences(1, target, nil)
	return err
}

func (SystemPreferences) Restore(snapshot []byte) error {
	if len(snapshot) == 0 {
		return errors.New("empty preferences snapshot")
	}
	_, _, err := preferences(2, 0, snapshot)
	return err
}
