package thermalguard

import (
	"errors"
	"github.com/charlie0129/gosmc"
	"math"
)

type temperatureReader interface {
	Read(string) (gosmc.Value, error)
}

// TB1T/TB2T are battery thermistors in Celsius (flt/sp78 depending on
// hardware). macOS 27 can omit IOKit's Temperature entirely. Use the hottest
// valid thermistor; IOKit is a fallback on hardware without these sensors.
// Primary reference: exelban/stats, Modules/Battery/readers.swift getTemperature.
func readBatteryTemperature(reader temperatureReader, iokit float64) (float64, error) {
	maximum := 0.0
	for _, key := range []string{"TB1T", "TB2T"} {
		value, err := reader.Read(key)
		if err != nil || value.Key != key {
			continue
		}
		celsius, err := value.Float64()
		if err == nil && validTemperature(celsius) && celsius > maximum {
			maximum = celsius
		}
	}
	if maximum > 0 {
		return maximum, nil
	}
	if validTemperature(iokit) {
		return iokit, nil
	}
	return 0, errors.New("battery temperature unavailable from SMC and IOKit")
}

func validTemperature(v float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0) && v > 0 && v <= 100
}

// BatteryTemperature returns the hottest valid battery thermistor, falling
// back to IOKit's reading when the SMC sensors are unavailable.
func BatteryTemperature(reader temperatureReader, iokit float64) (float64, error) {
	return readBatteryTemperature(reader, iokit)
}
