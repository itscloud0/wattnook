package main

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Foundation
#include <stdlib.h>
int hold_preferences(int operation, int target, void *input, int inputSize, void **output, int *outputSize, int *readLimit, char **message);
*/
import "C"

import (
	"errors"
	"unsafe"
)

func preferences(operation, target int, snapshot []byte) ([]byte, int, error) {
	var input unsafe.Pointer
	if len(snapshot) > 0 {
		input = C.CBytes(snapshot)
		defer C.free(input)
	}
	var output unsafe.Pointer
	var size, limit C.int
	var message *C.char
	ok := C.hold_preferences(C.int(operation), C.int(target), input, C.int(len(snapshot)), &output, &size, &limit, &message)
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
		return nil, 0, errors.New("preferences operation failed")
	}
	return C.GoBytes(output, size), int(limit), nil
}
