// Package status builds the public Feed Status snapshot served on :8081.
// JSON keys here are contractual (fw-gsd specs/003-usb-adsb-feeder
// contracts/feed-status.md) — do not rename.
package status

import "time"

// Snapshot is the /api/v1/feed/status response body.
type Snapshot struct {
	ReceiverPresent    bool          `json:"receiver_present"`
	AircraftTracked    int           `json:"aircraft_tracked"`
	ReadsbFreshnessS   float64       `json:"readsb_freshness_s"`
	FR24Configured     bool          `json:"fr24_configured"`
	FR24Connected      *bool         `json:"fr24_connected"`       // null when push disabled
	LastSuccessfulPush *string       `json:"last_successful_push"` // RFC3339 or null
	Degraded           DegradedState `json:"degraded"`
}

// Source carries the distilled probe outputs into Aggregate. The status
// package stays probe-agnostic; main maps probe results onto this struct.
type Source struct {
	ReceiverPresent  bool
	AircraftTracked  int
	ReadsbFreshnessS float64

	// PushEnabled mirrors FW_FR24_ENABLED.
	PushEnabled bool
	// KeyPresent mirrors the key-presence marker. NOTE: the status container
	// cannot see the fr24 sharing-key secret (research.md Decision 6 mounts
	// the podman secret only into fw-adsb-fr24feed), so "configured" is
	// derived as FW_FR24_ENABLED && FW_FR24_KEY_PRESENT_MARKER. Until the
	// quadlet wires that marker env, unset marker defaults to
	// enabled == configured. This is a deliberate assumption.
	KeyPresent bool

	// FR24 probe outcome (meaningful only when PushEnabled).
	FR24Reachable  bool       // status page probe succeeded
	FR24Connected  bool       // page reports tracker client connected
	FR24AuthFailed bool       // page contains an auth/key failure keyword
	LastPush       *time.Time // last observed successful/tracked push
}

// Aggregate combines probe outputs into the contracted Snapshot shape,
// deriving the degraded enum via MapDegraded.
func Aggregate(src Source) Snapshot {
	snap := Snapshot{
		ReceiverPresent:  src.ReceiverPresent,
		AircraftTracked:  src.AircraftTracked,
		ReadsbFreshnessS: src.ReadsbFreshnessS,
		FR24Configured:   src.PushEnabled && src.KeyPresent,
		Degraded: MapDegraded(Inputs{
			ReceiverPresent:    src.ReceiverPresent,
			PushEnabled:        src.PushEnabled,
			CredentialsMissing: src.PushEnabled && !src.KeyPresent,
			CredentialsInvalid: src.FR24AuthFailed,
			UpstreamReachable:  src.FR24Reachable,
		}),
	}
	if src.PushEnabled {
		connected := src.FR24Connected
		snap.FR24Connected = &connected // nil (JSON null) when push disabled
	}
	if src.LastPush != nil {
		s := src.LastPush.UTC().Format(time.RFC3339)
		snap.LastSuccessfulPush = &s
	}
	return snap
}
