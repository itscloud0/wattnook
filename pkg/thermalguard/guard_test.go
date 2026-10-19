package thermalguard

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fixtureHardware struct {
	held      bool
	writes    []bool
	failCut   bool
	sampleErr error
	foreign   string
}

func (f *fixtureHardware) Read() (string, error) {
	if f.foreign != "" {
		return f.foreign, nil
	}
	if f.held {
		return "held", nil
	}
	return "restored", nil
}
func (f *fixtureHardware) SetHeld(v bool) error {
	f.writes = append(f.writes, v)
	f.held = v
	if v && f.failCut {
		return errors.New("lost acknowledgement")
	}
	return nil
}
func (f *fixtureHardware) Sample() (Sample, error) {
	return Sample{Percent: 50, Temperature: 40, Connected: !f.held, Charging: !f.held, At: time.Now()}, f.sampleErr
}

type fixtureJournal struct {
	owned, recovered bool
	fail             bool
}

func (j *fixtureJournal) Load() (bool, bool, error) { return j.owned, j.recovered, nil }
func (j *fixtureJournal) Save(o, r bool) error {
	if j.fail {
		return errors.New("disk full")
	}
	j.owned, j.recovered = o, r
	return nil
}
func fixtureGuard() (*Guard, *fixtureHardware, *fixtureJournal) {
	h := &fixtureHardware{}
	j := &fixtureJournal{}
	return &Guard{Hardware: h, Journal: j}, h, j
}

func TestOwnershipAndOneCut(t *testing.T) {
	g, h, j := fixtureGuard()
	if err := g.Initialize(); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		r := g.Execute("hold")
		if r.Error != "" || r.Observed != "held" || !r.Owned {
			t.Fatalf("%+v", r)
		}
	}
	if len(h.writes) != 1 || !j.owned {
		t.Fatal("satisfied hold rewritten or not journaled")
	}
	r := g.Execute("restore")
	if r.Error != "" || r.Observed != "restored" || j.owned {
		t.Fatalf("%+v", r)
	}
	if len(h.writes) != 2 {
		t.Fatal(h.writes)
	}
	if r = g.Execute("hold"); r.Error == "" {
		t.Fatal("cooldown bypassed")
	}
}

func TestNoCutWithoutDurableOwnership(t *testing.T) {
	g, h, j := fixtureGuard()
	j.fail = true
	if r := g.Execute("hold"); r.Error == "" || len(h.writes) != 0 {
		t.Fatalf("unsafe cut: %+v %v", r, h.writes)
	}
	g, h, _ = fixtureGuard()
	h.foreign = "held"
	if err := g.Initialize(); err == nil || len(h.writes) != 0 {
		t.Fatal("foreign adapter overwritten")
	}
}

func TestUncertainCutRestoresAndLatches(t *testing.T) {
	g, h, j := fixtureGuard()
	h.failCut = true
	r := g.Execute("hold")
	if r.Error == "" || h.held || len(h.writes) != 2 || !j.recovered || j.owned {
		t.Fatalf("%+v writes=%v journal=%+v", r, h.writes, j)
	}
	if g.Execute("hold").Error == "" || len(h.writes) != 2 {
		t.Fatal("fault automatically rearmed")
	}
}

func TestStartupRecoversOnlyOurHold(t *testing.T) {
	g, h, j := fixtureGuard()
	h.held = true
	j.owned = true
	if err := g.Initialize(); err != nil {
		t.Fatal(err)
	}
	if h.held || !j.recovered || j.owned || len(h.writes) != 1 {
		t.Fatalf("recovery: %+v %+v", h, j)
	}
	if g.Execute("hold").Error == "" {
		t.Fatal("recovery did not latch")
	}
	if g.Execute("reset").Error != "" {
		t.Fatal("explicit reset rejected")
	}
}

func TestEOFAndHeartbeatRestore(t *testing.T) {
	for _, kind := range []string{"eof", "timeout"} {
		t.Run(kind, func(t *testing.T) {
			g, h, j := fixtureGuard()
			if kind == "eof" {
				if err := Serve(strings.NewReader("hold\n"), &bytes.Buffer{}, g, time.Second); err != nil {
					t.Fatal(err)
				}
			} else {
				reader, writer, err := os.Pipe()
				if err != nil {
					t.Fatal(err)
				}
				defer reader.Close()
				defer writer.Close()
				if _, err = writer.Write([]byte("hold\n")); err != nil {
					t.Fatal(err)
				}
				if err := Serve(reader, &bytes.Buffer{}, g, 30*time.Millisecond); err == nil {
					t.Fatal("expired lease accepted")
				}
			}
			if h.held || len(h.writes) != 2 || !j.recovered || j.owned {
				t.Fatalf("no emergency restoration: %+v %+v", h, j)
			}
		})
	}
}

func TestJournalPersistenceAndMalformedRecord(t *testing.T) {
	j := fileJournal{path: filepath.Join(t.TempDir(), "state.json")}
	if err := j.Save(true, false); err != nil {
		t.Fatal(err)
	}
	if owned, recovered, err := j.Load(); err != nil || !owned || recovered {
		t.Fatal(owned, recovered, err)
	}
	if err := os.WriteFile(j.path, []byte(`{"version":9,"owned":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := j.Load(); err == nil {
		t.Fatal("unknown recovery version accepted")
	}
}
