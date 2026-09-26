package probe

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fixture loads a testdata file, substituting __NOW__ with the current epoch
// so freshness assertions stay near zero.
func fixture(t *testing.T, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	now := float64(time.Now().UnixNano()) / 1e9
	return strings.ReplaceAll(string(raw), "__NOW__", fmt.Sprintf("%.3f", now))
}

func serveReadsb(t *testing.T, aircraft, stats string, statsStatus int) *ReadsbProbe {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/data/aircraft.json":
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, aircraft)
		case "/data/stats.json":
			if statsStatus != http.StatusOK {
				w.WriteHeader(statsStatus)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, stats)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return &ReadsbProbe{BaseURL: srv.URL}
}

func TestReadsbProbe_OneAircraft(t *testing.T) {
	p := serveReadsb(t, fixture(t, "aircraft_one.json"), fixture(t, "stats.json"), http.StatusOK)
	res, err := p.Probe(context.Background())
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.AircraftTracked != 1 {
		t.Fatalf("AircraftTracked = %d, want 1", res.AircraftTracked)
	}
	if res.FreshnessS < 0 || res.FreshnessS >= 5 {
		t.Fatalf("FreshnessS = %v, want 0 <= f < 5", res.FreshnessS)
	}
}

func TestReadsbProbe_EmptyAircraftIsHealthy(t *testing.T) {
	p := serveReadsb(t, fixture(t, "aircraft_empty.json"), fixture(t, "stats.json"), http.StatusOK)
	res, err := p.Probe(context.Background())
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.AircraftTracked != 0 {
		t.Fatalf("AircraftTracked = %d, want 0 (healthy)", res.AircraftTracked)
	}
}

func TestReadsbProbe_MalformedJSON(t *testing.T) {
	for _, body := range []string{
		fixture(t, "aircraft_malformed.json"),
		"definitely not json {",
		"",
	} {
		p := serveReadsb(t, body, fixture(t, "stats.json"), http.StatusOK)
		res, err := p.Probe(context.Background()) // must not panic
		if err == nil {
			t.Fatalf("body %q: expected error, got nil (res=%+v)", body, res)
		}
		if res != (ReadsbResult{}) {
			t.Fatalf("body %q: expected zero result on error, got %+v", body, res)
		}
	}
}

func TestReadsbProbe_MissingNow(t *testing.T) {
	p := serveReadsb(t, `{"aircraft": []}`, fixture(t, "stats.json"), http.StatusOK)
	_, err := p.Probe(context.Background())
	if err == nil {
		t.Fatal("expected error for missing now field")
	}
}

func TestReadsbProbe_StatsBestEffort(t *testing.T) {
	// stats.json broken must not fail the probe: aircraft.json carries the
	// contracted fields.
	p := serveReadsb(t, fixture(t, "aircraft_one.json"), "", http.StatusNotFound)
	res, err := p.Probe(context.Background())
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.AircraftTracked != 1 {
		t.Fatalf("AircraftTracked = %d, want 1", res.AircraftTracked)
	}
}

func TestReadsbProbe_Unreachable(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close() // dead target
	p := &ReadsbProbe{BaseURL: url}
	res, err := p.Probe(context.Background())
	if err == nil {
		t.Fatal("expected error for unreachable readsb")
	}
	if res != (ReadsbResult{}) {
		t.Fatalf("expected zero result, got %+v", res)
	}
}

// Data-model invariant 3: a fresh readsb snapshot has seen <= 65 for every
// aircraft (readsb aging contract). Validate the fixture used by the other
// tests complies.
func TestFixtureSeenInvariant(t *testing.T) {
	var doc struct {
		Aircraft []struct {
			Seen float64 `json:"seen"`
		} `json:"aircraft"`
	}
	if err := json.Unmarshal([]byte(fixture(t, "aircraft_one.json")), &doc); err != nil {
		t.Fatal(err)
	}
	for i, ac := range doc.Aircraft {
		if ac.Seen > 65 {
			t.Fatalf("aircraft[%d] seen=%v exceeds 65s aging contract", i, ac.Seen)
		}
	}
}
