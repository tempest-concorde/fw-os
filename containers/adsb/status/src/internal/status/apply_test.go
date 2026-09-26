package status

import (
	"testing"

	"github.com/tempest-concorde/fw-os/containers/adsb/status/internal/probe"
)

func TestApplyFR24State(t *testing.T) {
	cases := []struct {
		name                string
		state               probe.FR24State
		found               bool
		wantPushEnabled     bool
		wantKeyPresent      bool
		inputPush, inputKey bool
	}{
		{"absent marker leaves inference intact", "", false, true, true, true, true},
		{"absent marker leaves disabled intact", "", false, false, false, false, false},
		{"disabled overrides enabled env", probe.FR24StateDisabled, true, false, false, true, true},
		{"credentials_missing flips key", probe.FR24StateCredentialsMissing, true, true, false, false, true},
		{"active marks key present", probe.FR24StateActive, true, true, true, true, false},
		{"invalid_position keeps key-present push", probe.FR24StateInvalidPosition, true, true, true, false, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			src := &Source{PushEnabled: tc.inputPush, KeyPresent: tc.inputKey}
			ApplyFR24State(src, tc.state, tc.found)
			if src.PushEnabled != tc.wantPushEnabled || src.KeyPresent != tc.wantKeyPresent {
				t.Fatalf("got (%v,%v) want (%v,%v)",
					src.PushEnabled, src.KeyPresent, tc.wantPushEnabled, tc.wantKeyPresent)
			}
		})
	}
}
