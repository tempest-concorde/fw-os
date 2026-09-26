package probe

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// FR24StateFileName is the credential/runtime state marker written by the
// fw-adsb-fr24feed entrypoint into the shared fw-adsb-readsb-data volume
// (T048 / FR-017). Single-line values; see FR24State below.
const FR24StateFileName = "fr24-state"

// FR24State enumerates the marker values emitted by the fr24feed entrypoint.
type FR24State string

const (
	FR24StateActive             FR24State = "active"
	FR24StateDisabled           FR24State = "disabled"
	FR24StateCredentialsMissing FR24State = "credentials_missing"
	FR24StateInvalidPosition    FR24State = "invalid_position"
)

// FallbackFR24States lists marker values understood by this build, exported so
// tests and callers stay in sync.
var KnownFR24States = []FR24State{
	FR24StateActive, FR24StateDisabled, FR24StateCredentialsMissing, FR24StateInvalidPosition,
}

// FR24StateProbe reads the fr24feed entrypoint's marker from the shared data
// directory (mounted read-only in this container).
type FR24StateProbe struct{ Dir string }

// FR24StateResult reports the marker content. Found=false means the marker
// file does not exist (fr24feed has not (re)started yet, or the volume
// wiring is missing) — callers must fall back to config inference then.
type FR24StateResult struct {
	State FR24State
	Found bool
}

// Probe reads the marker. A missing file is not an error (Found=false);
// unreadable dirs/files and unknown content are errors.
func (p *FR24StateProbe) Probe(_ context.Context) (FR24StateResult, error) {
	b, err := os.ReadFile(filepath.Join(p.Dir, FR24StateFileName))
	if errors.Is(err, fs.ErrNotExist) {
		return FR24StateResult{}, nil
	}
	if err != nil {
		return FR24StateResult{}, fmt.Errorf("read %s: %w", FR24StateFileName, err)
	}
	s := FR24State(strings.TrimSpace(string(b)))
	for _, known := range KnownFR24States {
		if s == known {
			return FR24StateResult{State: s, Found: true}, nil
		}
	}
	return FR24StateResult{}, fmt.Errorf("unknown %s content %q", FR24StateFileName, s)
}
