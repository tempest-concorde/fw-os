package probe

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

const fr24ClientTimeout = 2 * time.Second

var (
	// "disconnected"/"not connected" must win over a bare "connected"
	// substring match ("disconnected" contains "connected").
	reFR24Disconnected = regexp.MustCompile(`(?i)\bdisconnected\b|\bnot\s+connected\b`)
	reFR24Connected    = regexp.MustCompile(`(?i)\bconnected\b`)
	// FR24 status page auth-failure phrasing, e.g. "authentication failed",
	// "invalid sharing key". Keywords only — never echoes page content upward.
	reFR24AuthFail = regexp.MustCompile(`(?i)(authenticat|authoriz).{0,60}(fail|error|invalid|denied|reject)` +
		`|(invalid|bad|wrong|missing).{0,30}(sharing.?key|key|credentials|password)`)
	reFR24Timestamp = regexp.MustCompile(`\b(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})\b`)
)

// FR24Result is the distilled signal from the fr24feed built-in status page.
type FR24Result struct {
	Connected  bool
	AuthFailed bool // page reports an authentication/key failure keyword
	LastPush   *time.Time
}

// FR24Probe scrapes the fr24feed container's status page (port 8754,
// internal network only — research.md Decision 3).
type FR24Probe struct {
	// BaseURL is e.g. "http://fw-adsb-fr24feed:8754"; "/" is appended.
	BaseURL string
	// Client is optional; a 2s-timeout client is used when nil.
	Client *http.Client

	now func() time.Time // test hook; nil means time.Now
}

// Probe fetches {BaseURL}/ and classifies the HTML body. When the page has a
// parseable timestamp it is used as LastPush, otherwise fetch time is the
// fallback on success. Callers skip this probe entirely when push is
// disabled (FW_FR24_ENABLED != true).
func (p *FR24Probe) Probe(ctx context.Context) (FR24Result, error) {
	if p == nil || p.BaseURL == "" {
		return FR24Result{}, errors.New("fr24 probe: empty base URL")
	}
	client := p.Client
	if client == nil {
		client = &http.Client{Timeout: fr24ClientTimeout}
	}
	url := strings.TrimRight(p.BaseURL, "/") + "/"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return FR24Result{}, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return FR24Result{}, fmt.Errorf("fr24 status page: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return FR24Result{}, fmt.Errorf("fr24 status page: unexpected status %s", resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return FR24Result{}, fmt.Errorf("fr24 status page read: %w", err)
	}

	text := string(body)
	res := FR24Result{}
	res.AuthFailed = reFR24AuthFail.MatchString(text)
	switch {
	case reFR24Disconnected.MatchString(text):
		res.Connected = false
	case reFR24Connected.MatchString(text):
		res.Connected = true
	}

	now := time.Now()
	if p.now != nil {
		now = p.now()
	}
	last := now.UTC()
	if m := reFR24Timestamp.FindStringSubmatch(text); m != nil {
		if ts, err := time.ParseInLocation("2006-01-02 15:04:05", m[1]+" "+m[2], time.UTC); err == nil {
			last = ts.UTC()
		}
	}
	res.LastPush = &last
	return res, nil
}
