package gui

import (
	"strings"
	"sync"

	"github.com/charlie0129/gosmc"
)

// socTemperature reads the hottest CPU/GPU die sensor through the SMC, read
// only. Battery temperature alone hides why a fanless Mac feels hot.
type socTemperature struct {
	once   sync.Once
	client *gosmc.Client
	keys   []string
}

var processorTemperature socTemperature

func (s *socTemperature) open() {
	client, err := gosmc.Open()
	if err != nil {
		return
	}
	n, err := client.KeyCount()
	if err != nil {
		_ = client.Close()
		return
	}
	for i := uint32(0); i < n; i++ {
		key, err := client.KeyAt(i)
		// Tp*: performance/efficiency cores, Tg*: GPU, Te*: efficiency cluster.
		if err != nil || !(strings.HasPrefix(key, "Tp") || strings.HasPrefix(key, "Tg") || strings.HasPrefix(key, "Te")) {
			continue
		}
		if value, err := client.Read(key); err == nil && value.DataType == "flt " {
			s.keys = append(s.keys, key)
		}
	}
	if len(s.keys) == 0 {
		_ = client.Close()
		return
	}
	s.client = client
}

// Celsius returns the hottest die reading, or -1 when unavailable.
func (s *socTemperature) Celsius() float64 {
	s.once.Do(s.open)
	if s.client == nil {
		return -1
	}
	hottest := -1.0
	for _, key := range s.keys {
		value, err := s.client.Read(key)
		if err != nil {
			continue
		}
		celsius, err := value.Float64()
		if err == nil && celsius > 10 && celsius < 130 && celsius > hottest {
			hottest = celsius
		}
	}
	return hottest
}
