package thermalguard

import (
	"encoding/binary"
	"errors"
	"github.com/charlie0129/gosmc"
	"math"
	"os"
	"testing"
)

type temperatureFixture map[string]gosmc.Value

func (f temperatureFixture) Read(key string) (gosmc.Value, error) {
	v, ok := f[key]
	if !ok {
		return v, errors.New("unavailable")
	}
	return v, nil
}
func temperatureValue(key string, celsius float32) gosmc.Value {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, math.Float32bits(celsius))
	return gosmc.Value{Key: key, DataType: "flt ", Bytes: b}
}

func TestBatteryTemperatureSurvivesMissingIOKitField(t *testing.T) {
	f := temperatureFixture{"TB1T": temperatureValue("TB1T", 36.2), "TB2T": temperatureValue("TB2T", 36.7)}
	v, err := readBatteryTemperature(f, 0)
	if err != nil || math.Abs(v-36.7) > 0.01 {
		t.Fatal(v, err)
	}
	delete(f, "TB2T")
	v, err = readBatteryTemperature(f, 0)
	if err != nil || math.Abs(v-36.2) > 0.01 {
		t.Fatal(v, err)
	}
}

func TestBatteryTemperatureRejectsMissingAndInvalidSensors(t *testing.T) {
	f := temperatureFixture{"TB1T": temperatureValue("TB1T", float32(math.NaN())), "TB2T": temperatureValue("TB2T", 200)}
	if _, err := readBatteryTemperature(f, 0); err == nil {
		t.Fatal("invalid temperatures accepted")
	}
	if value, err := readBatteryTemperature(f, 32); err != nil || value != 32 {
		t.Fatal(value, err)
	}
	f = temperatureFixture{"TB1T": {Key: "TB1T", DataType: "hex_", Bytes: []byte{30}}}
	if _, err := readBatteryTemperature(f, 0); err == nil {
		t.Fatal("unknown encoding accepted")
	}
}

func TestLiveBatteryTemperatureReadOnly(t *testing.T) {
	if os.Getenv("WATTNOOK_THERMAL_READ_ONLY") != "1" {
		t.Skip("explicit read-only host check")
	}
	c, err := gosmc.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	sample, err := (&nativeHardware{c: c}).Sample()
	if err != nil {
		t.Fatal(err)
	}
	if !validTemperature(sample.Temperature) || sample.Percent <= 0 || sample.Percent > 100 {
		t.Fatalf("invalid live battery sample: %+v", sample)
	}
	t.Logf("battery=%.0f%% temperature=%.2f°C AC=%t charging=%t", sample.Percent, sample.Temperature, sample.Connected, sample.Charging)
}
