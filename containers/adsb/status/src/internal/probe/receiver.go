package probe

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// ReceiverMarkerFile is the marker written into the shared /readsb volume by
// the readsb container start script once udev hands it the receiver.
const ReceiverMarkerFile = "receiver-present"

// ReceiverDefaultTTL is how fresh the marker mtime must be to count as
// present.
const ReceiverDefaultTTL = 60 * time.Second

// ReceiverProbe detects USB receiver presence via the marker file in the
// shared readsb data volume (data-model.md: receiver presence is a
// udev-derived signal surfaced to this container through the volume).
type ReceiverProbe struct {
	// Dir is the shared readsb data dir, e.g. /readsb.
	Dir string
	// TTL is the max marker mtime age; zero selects ReceiverDefaultTTL.
	TTL time.Duration

	now func() time.Time // test hook; nil means time.Now
}

// Probe reports presence = marker file exists AND mtime within TTL.
// A missing marker is a normal (false, nil) result, not an error.
func (p *ReceiverProbe) Probe(_ context.Context) (bool, error) {
	if p == nil || p.Dir == "" {
		return false, errors.New("receiver probe: empty dir")
	}
	fi, err := os.Stat(filepath.Join(p.Dir, ReceiverMarkerFile))
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return false, nil
		}
		return false, err
	}
	if !fi.Mode().IsRegular() { // tolerate directory-style markers too
		return true, nil
	}
	ttl := p.TTL
	if ttl <= 0 {
		ttl = ReceiverDefaultTTL
	}
	now := time.Now()
	if p.now != nil {
		now = p.now()
	}
	return now.Sub(fi.ModTime()) < ttl, nil
}
