package smc

import (
	"io"
	"testing"

	"github.com/charlie0129/gosmc"
	"github.com/sirupsen/logrus"
	logtest "github.com/sirupsen/logrus/hooks/test"
)

// A rejected write must never appear in diagnostics as a successful command.
// Both byte and typed writes must be visible at the installed daemon's Debug level.
func TestWriteAuditReportsActualOutcome(t *testing.T) {
	logger := logrus.StandardLogger()
	previousLevel, previousOutput := logger.GetLevel(), logger.Out
	previousHooks := logger.ReplaceHooks(make(logrus.LevelHooks))
	t.Cleanup(func() {
		logger.SetLevel(previousLevel)
		logger.SetOutput(previousOutput)
		logger.ReplaceHooks(previousHooks)
	})
	logger.SetLevel(logrus.DebugLevel)
	logger.SetOutput(io.Discard)
	hook := logtest.NewGlobal()
	client := openMockSMC(t,
		smcValue(t, ChargingKey1, gosmc.TypeUInt8, 0),
		smcValue(t, FirmwareChargeLimitUpperKey, gosmc.TypeUInt32, 0, 0, 0, 0),
	)
	for _, test := range []struct {
		name        string
		key         string
		write       func() error
		wantSuccess bool
	}{
		{"bytes success", ChargingKey1, func() error { return client.Write(ChargingKey1, []byte{2}) }, true},
		{"bytes rejected", ChargingKey1, func() error { return client.Write(ChargingKey1, []byte{0, 0}) }, false},
		{"typed success", FirmwareChargeLimitUpperKey, func() error { return client.WriteUint32(FirmwareChargeLimitUpperKey, 80) }, true},
		{"typed rejected", "NONE", func() error { return client.WriteUint32("NONE", 80) }, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			hook.Reset()
			err := test.write()
			if (err == nil) != test.wantSuccess {
				t.Fatalf("write error = %v, wantSuccess=%t", err, test.wantSuccess)
			}
			var outcomes []*logrus.Entry
			for _, entry := range hook.AllEntries() {
				if _, ok := entry.Data["success"]; ok {
					outcomes = append(outcomes, entry)
				}
			}
			if len(outcomes) != 1 {
				t.Fatalf("want one write outcome in diagnostics, got %d", len(outcomes))
			}
			entry := outcomes[0]
			if entry.Data["key"] != test.key || entry.Data["success"] != test.wantSuccess {
				t.Fatalf("incorrect write outcome: %v", entry.Data)
			}
			if !test.wantSuccess && entry.Data[logrus.ErrorKey] == nil {
				t.Fatal("rejected command must include its error")
			}
		})
	}
}
