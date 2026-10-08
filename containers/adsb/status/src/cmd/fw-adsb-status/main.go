// fw-adsb-status is the Flight Wall OS ADS-B feed status aggregator
// (fw-gsd specs/003-usb-adsb-feeder). It probes readsb, fr24feed and the
// receiver marker, caches a Snapshot atomically, and serves:
//
//	GET /api/v1/feed/status  contracted JSON (contracts/feed-status.md)
//	GET /metrics             Prometheus text exposition
//	GET /healthz             "ok"
//
// Handlers read only the cached snapshot (never block on probes); probing
// happens in a background loop. Dead upstreams degrade output, not uptime.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/tempest-concorde/fw-os/containers/adsb/status/internal/probe"
	"github.com/tempest-concorde/fw-os/containers/adsb/status/internal/status"
)

const (
	envAddr           = "FW_ADSB_STATUS_ADDR"
	envInterval       = "FW_ADSB_STATUS_INTERVAL"
	envReadsbURL      = "FW_ADSB_READSB_URL"
	envFR24URL        = "FW_ADSB_FR24_URL"
	envDataDir        = "FW_ADSB_DATA_DIR"
	envFR24Enabled    = "FW_FR24_ENABLED"
	envFR24KeyMarker  = "FW_FR24_KEY_PRESENT_MARKER"
	receiverDeviceID  = "/dev/rtl-sdr0" // udev-derived stable id (data-model.md)
	defaultAddr       = ":8081"
	defaultInterval   = 5 * time.Second
	defaultReadsbURL  = "http://fw-adsb-readsb:8080"
	defaultFR24URL    = "http://fw-adsb-fr24feed:8754"
	defaultDataDir    = "/readsb"
	shutdownTimeout   = 5 * time.Second
	readHeaderTimeout = 5 * time.Second
)

type config struct {
	addr        string
	interval    time.Duration
	readsbURL   string
	fr24URL     string
	dataDir     string
	fr24Enabled bool
	keyPresent  bool // see note in status.Source: enabled==configured by default
}

// loadConfig fails fast ONLY on unparseable values; a missing upstream URL
// or disabled feed is never fatal.
func loadConfig(getenv func(string) (string, bool)) (config, error) {
	cfg := config{
		addr:       defaultAddr,
		interval:   defaultInterval,
		readsbURL:  defaultReadsbURL,
		fr24URL:    defaultFR24URL,
		dataDir:    defaultDataDir,
		keyPresent: true, // provisional; resolved below
	}
	if v, ok := getenv(envAddr); ok && v != "" {
		cfg.addr = v
	}
	if v, ok := getenv(envReadsbURL); ok && v != "" {
		cfg.readsbURL = v
	}
	if v, ok := getenv(envFR24URL); ok && v != "" {
		cfg.fr24URL = v
	}
	if v, ok := getenv(envDataDir); ok && v != "" {
		cfg.dataDir = v
	}
	if v, ok := getenv(envInterval); ok && v != "" {
		d, err := parseInterval(v)
		if err != nil {
			return config{}, fmt.Errorf("%s: %w", envInterval, err)
		}
		cfg.interval = d
	}
	if v, ok := getenv(envFR24Enabled); ok && v != "" {
		b, err := parseBool(v)
		if err != nil {
			return config{}, fmt.Errorf("%s: %w", envFR24Enabled, err)
		}
		cfg.fr24Enabled = b
	}
	// The status container cannot see the fr24 secret (Decision 6), so it
	// trusts a marker env instead. Unset/unparseable marker => assume the
	// key exists when push is enabled (until the quadlet wires the marker).
	if v, ok := getenv(envFR24KeyMarker); ok {
		if b, err := parseBool(v); err == nil {
			cfg.keyPresent = b
		}
	}
	return cfg, nil
}

func parseInterval(s string) (time.Duration, error) {
	if d, err := time.ParseDuration(s); err == nil && d > 0 {
		return d, nil
	}
	if n, err := strconv.Atoi(s); err == nil && n > 0 {
		return time.Duration(n) * time.Second, nil
	}
	return 0, fmt.Errorf("unparseable interval %q (want e.g. \"5s\" or \"5\")", s)
}

func parseBool(s string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "true", "1", "yes", "on":
		return true, nil
	case "false", "0", "no", "off":
		return false, nil
	default:
		return false, fmt.Errorf("unparseable boolean %q", s)
	}
}

// poller owns the probe cycle and the atomically-swapped snapshot cache.
type poller struct {
	cfg       config
	readsb    *probe.ReadsbProbe
	fr24      *probe.FR24Probe
	fr24state *probe.FR24StateProbe
	receiver  *probe.ReceiverProbe

	snap atomic.Pointer[status.Snapshot]

	mu         sync.Mutex
	lastPush   *time.Time
	lastReadsb probe.ReadsbResult
	haveReadsb bool
}

func newPoller(cfg config) *poller {
	p := &poller{
		cfg:       cfg,
		readsb:    &probe.ReadsbProbe{BaseURL: cfg.readsbURL},
		fr24:      &probe.FR24Probe{BaseURL: cfg.fr24URL},
		fr24state: &probe.FR24StateProbe{Dir: cfg.dataDir},
		receiver:  &probe.ReceiverProbe{Dir: cfg.dataDir},
	}
	p.poll(context.Background()) // seed a sane first snapshot
	return p
}

func (p *poller) snapshot() *status.Snapshot { return p.snap.Load() }

func (p *poller) poll(ctx context.Context) {
	src := status.Source{PushEnabled: p.cfg.fr24Enabled, KeyPresent: p.cfg.keyPresent}

	// Ground-truth credential state from the fr24 container (T048): overrides
	// the enabled==configured inference before degraded mapping.
	if res, err := p.fr24state.Probe(ctx); err != nil {
		slog.Warn("fr24-state marker probe failed; keeping inference", "err", err)
	} else {
		status.ApplyFR24State(&src, res.State, res.Found)
	}

	if present, err := p.receiver.Probe(ctx); err != nil {
		slog.Warn("receiver probe failed", "err", err)
	} else {
		src.ReceiverPresent = present
	}

	if res, err := p.readsb.Probe(ctx); err != nil {
		slog.Warn("readsb probe failed; serving last-good values", "err", err)
	} else {
		p.mu.Lock()
		p.lastReadsb, p.haveReadsb = res, true
		p.mu.Unlock()
	}
	p.mu.Lock()
	if p.haveReadsb {
		src.AircraftTracked = p.lastReadsb.AircraftTracked
		src.ReadsbFreshnessS = p.lastReadsb.FreshnessS
	}
	p.mu.Unlock()

	if src.PushEnabled {
		if res, err := p.fr24.Probe(ctx); err != nil {
			slog.Warn("fr24 probe failed", "err", err) // UpstreamReachable stays false
		} else {
			src.FR24Reachable = true
			src.FR24Connected = res.Connected
			src.FR24AuthFailed = res.AuthFailed
			if res.LastPush != nil {
				p.mu.Lock()
				lp := *res.LastPush
				p.lastPush = &lp
				p.mu.Unlock()
			}
		}
	}

	p.mu.Lock()
	src.LastPush = p.lastPush
	p.mu.Unlock()

	s := status.Aggregate(src)
	p.snap.Store(&s)
}

func (p *poller) loop(ctx context.Context) {
	t := time.NewTicker(p.cfg.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.poll(ctx)
		}
	}
}

// --- HTTP handlers (read the cache only; CONTRACT: respond in <= 1s) ---

func handleStatus(p *poller) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		snap := p.snapshot()
		if snap == nil {
			snap = &status.Snapshot{} // defensive; poller seeds at startup
		}
		if err := json.NewEncoder(w).Encode(snap); err != nil {
			slog.Error("encode status failed", "err", err)
		}
	}
}

func boolGauge(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// escLabel escapes a Prometheus label value per the text exposition format.
func escLabel(v string) string {
	return strings.NewReplacer(`\`, `\\`, "\n", `\n`, `"`, `\"`).Replace(v)
}

func handleMetrics(p *poller) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		snap := p.snapshot()
		if snap == nil {
			snap = &status.Snapshot{}
		}
		var b strings.Builder
		b.WriteString("# HELP fw_adsb_receiver_present Receiver present (1) or absent (0).\n")
		b.WriteString("# TYPE fw_adsb_receiver_present gauge\n")
		fmt.Fprintf(&b, "fw_adsb_receiver_present{device=\"%s\"} %s\n",
			escLabel(receiverDeviceID), boolGauge(snap.ReceiverPresent))
		b.WriteString("# HELP fw_adsb_aircraft_tracked Aircraft currently tracked by readsb.\n")
		b.WriteString("# TYPE fw_adsb_aircraft_tracked gauge\n")
		fmt.Fprintf(&b, "fw_adsb_aircraft_tracked %d\n", snap.AircraftTracked)
		b.WriteString("# HELP fw_adsb_readsb_freshness_seconds Seconds since readsb's latest decoded data.\n")
		b.WriteString("# TYPE fw_adsb_readsb_freshness_seconds gauge\n")
		fmt.Fprintf(&b, "fw_adsb_readsb_freshness_seconds %s\n",
			strconv.FormatFloat(snap.ReadsbFreshnessS, 'f', -1, 64))
		// Omitted entirely when push is disabled (contract).
		if snap.FR24Connected != nil {
			b.WriteString("# HELP fw_adsb_fr24_connected FR24 tracker client connected (1/0).\n")
			b.WriteString("# TYPE fw_adsb_fr24_connected gauge\n")
			fmt.Fprintf(&b, "fw_adsb_fr24_connected %s\n", boolGauge(*snap.FR24Connected))
		}
		// Unknown epoch (no push yet) is omitted rather than emitted as 0.
		if snap.LastSuccessfulPush != nil {
			if ts, err := time.Parse(time.RFC3339, *snap.LastSuccessfulPush); err == nil {
				b.WriteString("# HELP fw_adsb_last_push_timestamp_seconds Last successful FR24 push (unix epoch).\n")
				b.WriteString("# TYPE fw_adsb_last_push_timestamp_seconds gauge\n")
				fmt.Fprintf(&b, "fw_adsb_last_push_timestamp_seconds %d\n", ts.Unix())
			}
		}
		b.WriteString("# HELP fw_adsb_degraded Current degraded state (1 active, 0 otherwise).\n")
		b.WriteString("# TYPE fw_adsb_degraded gauge\n")
		for _, st := range status.AllStates {
			active := "0"
			if snap.Degraded == st {
				active = "1"
			}
			fmt.Fprintf(&b, "fw_adsb_degraded{state=\"%s\"} %s\n", escLabel(string(st)), active)
		}
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		if _, err := fmt.Fprint(w, b.String()); err != nil {
			slog.Error("write metrics failed", "err", err)
		}
	}
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	if _, err := fmt.Fprintln(w, "ok"); err != nil {
		slog.Error("write healthz failed", "err", err)
	}
}

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, nil)))
	if err := run(); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := loadConfig(os.LookupEnv)
	if err != nil {
		return err // fail fast on unparseable config only
	}
	slog.Info("starting fw-adsb-status",
		"addr", cfg.addr,
		"interval", cfg.interval.String(),
		"readsb_url", cfg.readsbURL,
		"fr24_url", cfg.fr24URL,
		"fr24_enabled", cfg.fr24Enabled,
		"data_dir", cfg.dataDir,
	)

	p := newPoller(cfg)

	mux := http.NewServeMux()
	mux.Handle("GET /api/v1/feed/status", handleStatus(p))
	mux.Handle("GET /metrics", handleMetrics(p))
	mux.HandleFunc("GET /healthz", handleHealthz)

	srv := &http.Server{
		Addr:              cfg.addr,
		Handler:           mux,
		ReadHeaderTimeout: readHeaderTimeout,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go p.loop(ctx)

	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()

	select {
	case <-ctx.Done():
		slog.Info("shutting down")
		sctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		return srv.Shutdown(sctx)
	case err := <-errc:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}
