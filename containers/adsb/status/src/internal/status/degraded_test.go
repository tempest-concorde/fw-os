package status

import "testing"

// Truth table: receiver {off,on} x {disabled,missing,invalid,unreachable,ok}.
// Priority (contracts/feed-status.md): no_receiver > credentials_missing >
// credentials_invalid > upstream_unreachable > ok.
func TestMapDegraded_TruthTable(t *testing.T) {
	rows := []struct {
		name string
		in   Inputs
		want DegradedState
	}{
		// Receiver absent: always no_receiver regardless of push inputs
		// (data-model invariant 1).
		{"receiver_off/disabled", Inputs{ReceiverPresent: false}, StateNoReceiver},
		{"receiver_off/missing", Inputs{ReceiverPresent: false, PushEnabled: true, CredentialsMissing: true}, StateNoReceiver},
		{"receiver_off/invalid", Inputs{ReceiverPresent: false, PushEnabled: true, CredentialsInvalid: true, UpstreamReachable: true}, StateNoReceiver},
		{"receiver_off/unreachable", Inputs{ReceiverPresent: false, PushEnabled: true, UpstreamReachable: false}, StateNoReceiver},
		{"receiver_off/ok", Inputs{ReceiverPresent: false, PushEnabled: true, UpstreamReachable: true}, StateNoReceiver},

		// Receiver present, push disabled: always ok (data-model invariant 2:
		// fr24_configured=false => push disabled => no push-derived states).
		{"receiver_on/disabled", Inputs{ReceiverPresent: true}, StateOK},
		{"receiver_on/disabled_with_bad_push_inputs", Inputs{
			ReceiverPresent:    true,
			PushEnabled:        false,
			CredentialsMissing: true,
			CredentialsInvalid: true,
			UpstreamReachable:  false,
		}, StateOK},

		// Receiver present, push enabled.
		{"receiver_on/missing", Inputs{ReceiverPresent: true, PushEnabled: true, CredentialsMissing: true}, StateCredentialsMissing},
		{"receiver_on/invalid", Inputs{ReceiverPresent: true, PushEnabled: true, CredentialsInvalid: true, UpstreamReachable: true}, StateCredentialsInvalid},
		{"receiver_on/unreachable", Inputs{ReceiverPresent: true, PushEnabled: true, UpstreamReachable: false}, StateUpstreamUnreachable},
		{"receiver_on/ok", Inputs{ReceiverPresent: true, PushEnabled: true, UpstreamReachable: true}, StateOK},

		// Precedence among push-enabled failures.
		{"missing_beats_invalid", Inputs{ReceiverPresent: true, PushEnabled: true, CredentialsMissing: true, CredentialsInvalid: true, UpstreamReachable: true}, StateCredentialsMissing},
		{"missing_beats_unreachable", Inputs{ReceiverPresent: true, PushEnabled: true, CredentialsMissing: true, UpstreamReachable: false}, StateCredentialsMissing},
		{"invalid_beats_unreachable", Inputs{ReceiverPresent: true, PushEnabled: true, CredentialsInvalid: true, UpstreamReachable: false}, StateCredentialsInvalid},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			if got := MapDegraded(row.in); got != row.want {
				t.Fatalf("MapDegraded(%+v) = %q, want %q", row.in, got, row.want)
			}
		})
	}
}

// Invariant: every AllStates entry must be reachable and distinct.
func TestAllStatesDistinctAndReachable(t *testing.T) {
	seen := map[DegradedState]bool{}
	for _, s := range AllStates {
		if s == "" {
			t.Fatal("AllStates contains empty state")
		}
		if seen[s] {
			t.Fatalf("AllStates contains duplicate %q", s)
		}
		seen[s] = true
	}
	reachable := map[DegradedState]bool{
		MapDegraded(Inputs{ReceiverPresent: true, PushEnabled: false}):                                                   true,
		MapDegraded(Inputs{ReceiverPresent: true, PushEnabled: true, UpstreamReachable: true}):                           true,
		MapDegraded(Inputs{ReceiverPresent: false}):                                                                      true,
		MapDegraded(Inputs{ReceiverPresent: true, PushEnabled: true, CredentialsMissing: true}):                          true,
		MapDegraded(Inputs{ReceiverPresent: true, PushEnabled: true, CredentialsInvalid: true, UpstreamReachable: true}): true,
		MapDegraded(Inputs{ReceiverPresent: true, PushEnabled: true, UpstreamReachable: false}):                          true,
	}
	for _, s := range AllStates {
		if !reachable[s] {
			t.Fatalf("state %q is not reachable via MapDegraded", s)
		}
	}
}
