package probe

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestFR24StateProbe(t *testing.T) {
	ctx := context.Background()

	t.Run("absent marker is Found=false without error", func(t *testing.T) {
		p := &FR24StateProbe{Dir: t.TempDir()}
		res, err := p.Probe(ctx)
		if err != nil || res.Found {
			t.Fatalf("got (%+v, %v), want Found=false, nil err", res, err)
		}
	})

	t.Run("missing directory is Found=false without error", func(t *testing.T) {
		p := &FR24StateProbe{Dir: filepath.Join(t.TempDir(), "nonexistent")}
		res, err := p.Probe(ctx)
		if err != nil || res.Found {
			t.Fatalf("got (%+v, %v), want Found=false, nil err", res, err)
		}
	})

	states := []string{"active", "disabled", "credentials_missing", "invalid_position"}
	for _, s := range states {
		t.Run("parses "+s, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, FR24StateFileName), []byte(s+"\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			res, err := (&FR24StateProbe{Dir: dir}).Probe(ctx)
			if err != nil || !res.Found || string(res.State) != s {
				t.Fatalf("got (%+v, %v), want state=%q", res, err, s)
			}
		})
	}

	t.Run("unknown content is an error", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, FR24StateFileName), []byte("bogus"), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := (&FR24StateProbe{Dir: dir}).Probe(ctx); err == nil {
			t.Fatal("want error for unknown marker content")
		}
	})
}
