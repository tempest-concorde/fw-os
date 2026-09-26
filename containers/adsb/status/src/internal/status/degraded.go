package status

// DegradedState enumerates the contracted degraded values
// (contracts/feed-status.md, data-model.md Feed Status).
type DegradedState string

const (
	StateOK                  DegradedState = "ok"
	StateNoReceiver          DegradedState = "no_receiver"
	StateUpstreamUnreachable DegradedState = "upstream_unreachable"
	StateCredentialsInvalid  DegradedState = "credentials_invalid"
	StateCredentialsMissing  DegradedState = "credentials_missing"
)

// AllStates lists every state; used by the /metrics renderer to emit one
// fw_adsb_degraded series per state.
var AllStates = []DegradedState{
	StateOK,
	StateNoReceiver,
	StateUpstreamUnreachable,
	StateCredentialsInvalid,
	StateCredentialsMissing,
}

// Inputs are the raw signals mapped onto a DegradedState. CredentialMissing
// and CredentialsInvalid only apply when PushEnabled.
type Inputs struct {
	ReceiverPresent    bool
	PushEnabled        bool
	CredentialsMissing bool // push enabled but sharing-key marker absent
	CredentialsInvalid bool // fr24 status page reports auth/key failure
	UpstreamReachable  bool // fr24 status page probe succeeded
}

// MapDegraded is a pure function implementing the contracted priority:
//
//	receiver absent            -> no_receiver
//	push enabled, key missing  -> credentials_missing
//	push enabled, auth failure -> credentials_invalid
//	push enabled, upstream down-> upstream_unreachable
//	otherwise                  -> ok
//
// Data-model invariants honoured here:
//  1. receiver_present=false => no_receiver (always wins).
//  2. fr24_configured=false => push disabled => credential/upstream states
//     never fire regardless of the credential/upstream inputs.
func MapDegraded(in Inputs) DegradedState {
	if !in.ReceiverPresent {
		return StateNoReceiver
	}
	if !in.PushEnabled {
		return StateOK
	}
	if in.CredentialsMissing {
		return StateCredentialsMissing
	}
	if in.CredentialsInvalid {
		return StateCredentialsInvalid
	}
	if !in.UpstreamReachable {
		return StateUpstreamUnreachable
	}
	return StateOK
}
