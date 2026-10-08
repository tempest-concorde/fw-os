package status

import "github.com/tempest-concorde/fw-os/containers/adsb/status/internal/probe"

// ApplyFR24State maps the fw-adsb-fr24feed entrypoint's fr24-state marker
// (T048 / FR-017) onto Source before aggregation. It is ground truth from the
// fr24 container itself and overrides config inference:
//
//	disabled => push treated as off (config env may be stale)
//	credentials_missing => push on, key absent (=> degraded credentials_missing)
//	active => push on, key present
//	invalid_position => push on, key present; the position misconfiguration
//	  surfaces through the runtime fr24 probe (idle process => unreachable
//	  => upstream_unreachable), because the degraded enum has no dedicated
//	  value for it (contract: 5 values only).
func ApplyFR24State(src *Source, state probe.FR24State, found bool) {
	if !found {
		return
	}
	switch state {
	case probe.FR24StateDisabled:
		// Key presence is meaningless while push is off.
		src.PushEnabled, src.KeyPresent = false, false
	case probe.FR24StateCredentialsMissing:
		src.PushEnabled, src.KeyPresent = true, false
	case probe.FR24StateActive, probe.FR24StateInvalidPosition:
		src.PushEnabled, src.KeyPresent = true, true
	}
}
