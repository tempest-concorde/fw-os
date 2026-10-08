package probe

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"time"
)

const readsbClientTimeout = 2 * time.Second

// ReadsbResult is the distilled health signal extracted from readsb's
// tar1090-format HTTP surface (research.md Decision 5).
type ReadsbResult struct {
	AircraftTracked int
	FreshnessS      float64
}

// ReadsbProbe polls the readsb container's HTTP data directory.
type ReadsbProbe struct {
	// BaseURL is e.g. "http://fw-adsb-readsb:8080"; paths below are appended.
	BaseURL string
	// Client is optional; a 2s-timeout client is used when nil.
	Client *http.Client

	now func() time.Time // test hook; nil means time.Now
}

// aircraftFile mirrors the subset of readsb's aircraft.json we consume.
// Aircraft is RawMessage so that per-aircraft schema drift never fails the
// decode; only the envelope matters here.
type aircraftFile struct {
	Now      *float64          `json:"now"`
	Aircraft []json.RawMessage `json:"aircraft"`
}

// Probe fetches {BaseURL}/data/aircraft.json and /data/stats.json.
// aircraft.json is the primary signal: count = len("aircraft") (absent ⇒ 0,
// which is a healthy value), freshness = time since the "now" epoch float.
// stats.json is a best-effort secondary health signal: it is fetched and
// JSON-validated, but a malformed/absent stats.json does not fail the probe
// (aircraft.json alone carries the contracted fields).
//
// Robust to garbage: any transport or decode failure returns zero values
// plus an error; it never panics on malformed input.
func (p *ReadsbProbe) Probe(ctx context.Context) (ReadsbResult, error) {
	if p == nil || p.BaseURL == "" {
		return ReadsbResult{}, errors.New("readsb probe: empty base URL")
	}
	base := strings.TrimRight(p.BaseURL, "/")

	// Secondary: stats.json (best effort).
	statsOK := true
	if body, err := p.get(ctx, base+"/data/stats.json"); err != nil {
		statsOK = false
	} else {
		var stats map[string]json.RawMessage
		if err := json.Unmarshal(body, &stats); err != nil {
			statsOK = false
		}
	}
	_ = statsOK // reserved for future enriched reporting

	// Primary: aircraft.json.
	body, err := p.get(ctx, base+"/data/aircraft.json")
	if err != nil {
		return ReadsbResult{}, fmt.Errorf("readsb aircraft.json: %w", err)
	}
	var af aircraftFile
	if err := json.Unmarshal(body, &af); err != nil {
		return ReadsbResult{}, fmt.Errorf("readsb aircraft.json decode: %w", err)
	}

	var res ReadsbResult
	res.AircraftTracked = len(af.Aircraft) // absent array ⇒ 0 (healthy)

	if af.Now == nil || *af.Now <= 0 {
		return res, errors.New("readsb aircraft.json: missing/invalid now field")
	}
	epoch := *af.Now
	sec, frac := math.Modf(epoch)
	stamp := time.Unix(int64(sec), int64(frac*1e9)).UTC()
	freshness := p.nowFn().Sub(stamp).Seconds()
	if freshness < 0 {
		freshness = 0 // clock skew against readsb host; contract requires >= 0
	}
	res.FreshnessS = math.Round(freshness*1000) / 1000
	return res, nil
}

func (p *ReadsbProbe) get(ctx context.Context, url string) ([]byte, error) {
	client := p.Client
	if client == nil {
		client = &http.Client{Timeout: readsbClientTimeout}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status %s", resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 4<<20))
}

func (p *ReadsbProbe) nowFn() time.Time {
	if p.now != nil {
		return p.now()
	}
	return time.Now()
}
