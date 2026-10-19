package powerui

import (
	"errors"
	"os"
	"reflect"
	"testing"
	"time"
)

func TestHostReadOnly(t *testing.T) {
	if os.Getenv("WATTNOOK_NATIVE_READ_ONLY") != "1" {
		t.Skip("explicit host read-only smoke test")
	}
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	s, err := c.Read()
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("Apple native limit=%d enabled=%t available=%v", s.EffectiveLimit(), s.Enabled, s.Limits)
}

type fakeBackend struct {
	state  State
	err    error
	writes []int
	ignore bool
	block  <-chan struct{}
}

func (f *fakeBackend) Read() (State, error) {
	if f.block != nil {
		<-f.block
	}
	return f.state, f.err
}
func (f *fakeBackend) Set(v int) error {
	f.writes = append(f.writes, v)
	if !f.ignore {
		f.state.Limit = v
		f.state.Enabled = v < 100
	}
	return f.err
}

// These catch stale-config writes, unsupported values and unverified success.
func TestChangeValidatesAndVerifies(t *testing.T) {
	f := &fakeBackend{state: State{Limit: 80, Enabled: true, Limits: []int{80, 85, 90, 95, 100}}}
	c := newController(f, time.Second)
	if err := c.SetLimit(70); err == nil {
		t.Fatal("unsupported limit accepted")
	}
	if len(f.writes) != 0 {
		t.Fatal("invalid request changed system")
	}
	if err := c.SetLimit(85); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(f.writes, []int{85}) {
		t.Fatal(f.writes)
	}
	f.ignore = true
	if err := c.SetLimit(90); err == nil {
		t.Fatal("readback mismatch accepted")
	}
	f.err = errors.New("unavailable")
	if err := c.SetLimit(95); err == nil {
		t.Fatal("read failure accepted")
	}
	if !reflect.DeepEqual(f.writes, []int{85, 90}) {
		t.Fatal("write after failed refresh", f.writes)
	}
}

func TestReadFollowsExternalSettingWithoutWrites(t *testing.T) {
	f := &fakeBackend{state: State{Limit: 80, Enabled: true, Limits: []int{80, 90, 100}}}
	c := newController(f, time.Second)
	for _, want := range []int{80, 90, 100} {
		f.state.Limit = want
		f.state.Enabled = want < 100
		s, err := c.Read()
		if err != nil || s.EffectiveLimit() != want {
			t.Fatalf("%+v %v", s, err)
		}
	}
	if len(f.writes) != 0 {
		t.Fatal("passive read changed system")
	}
	f.state.Enabled = false
	f.state.Limit = 80
	s, err := c.Read()
	if err != nil || s.EffectiveLimit() != 100 {
		t.Fatal("disabled limit represented as active")
	}
}

func TestTimeoutDoesNotQueueMoreOperations(t *testing.T) {
	release := make(chan struct{})
	f := &fakeBackend{block: release, state: State{Limit: 80, Enabled: true, Limits: []int{80, 100}}}
	c := newController(f, 10*time.Millisecond)
	defer close(release)
	if _, err := c.Read(); err == nil {
		t.Fatal("blocked read succeeded")
	}
	if err := c.SetLimit(100); err == nil {
		t.Fatal("operation queued behind stalled call")
	}
}

func TestMalformedSystemStateUnavailable(t *testing.T) {
	for _, s := range []State{
		{Limit: 0, Enabled: true, Limits: []int{80, 100}},
		{Limit: 80, Enabled: true},
		{Limit: 80, Enabled: true, Limits: []int{0, 80}},
	} {
		c := newController(&fakeBackend{state: s}, time.Second)
		if _, err := c.Read(); err == nil {
			t.Fatalf("invalid state accepted: %+v", s)
		}
	}
}

func TestExplicit100DisablesEvenIfEnabledLimitIs100(t *testing.T) {
	f := &fakeBackend{state: State{Limit: 100, Enabled: true, Limits: []int{80, 100}}}
	c := newController(f, time.Second)
	if err := c.SetLimit(100); err != nil {
		t.Fatal(err)
	}
	if f.state.Enabled || len(f.writes) != 1 {
		t.Fatal("100 request did not disable native limiting")
	}
}

func TestSequentialReadsDoNotReportBusy(t *testing.T) {
	c := newController(&fakeBackend{state: State{Limit: 80, Enabled: true, Limits: []int{80, 100}}}, time.Second)
	for i := 0; i < 10000; i++ {
		if _, err := c.Read(); err != nil {
			t.Fatal(err)
		}
	}
}
