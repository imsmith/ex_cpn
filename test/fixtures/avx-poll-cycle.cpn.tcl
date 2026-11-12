# arch/action-models/avx-poll-cycle.cpn.tcl
#
# Canonical sequence of events for one successful poll cycle for one
# endpoint, plus failure paths and concurrency gates. Realises the
# behavioural decisions in ADRs 0002, 0003, 0004, and 0005.
#
# Place types reference real YANG containers and groupings in the
# specification stack. Where a concept used in the ADR prose (e.g.
# "framework-http-request") did not have a direct YANG home, the place
# type is the nearest structural container that does exist.

cpn-spec 1.0

yang import avx-api-integration
yang import avx-ccf-connector
yang import avx-common
yang import avx-azure

# Places (ADR-0002 happy path)

place framework-request     -type avx-api-integration:api-requests
place token-validated       -type avx-api-integration:api-requests
place session-available     -type avx-api-integration:session-state
place controller-response   -type avx-api-integration:api-requests
place sub-batches           -type avx-api-integration:pagination-config
place ledger-written        -type avx-api-integration:inflight-ledger
place deduplicated          -type avx-api-integration:inflight-ledger
place normalised            -type avx-api-integration:api-requests
place correlated            -type avx-api-integration:api-requests
place response-sent         -type avx-api-integration:api-requests
# response-completed removed by ADR-0006 (no read-completion signal in Functions v1 Python runtime).
place cursor-advanced       -type avx-api-integration:integration-state
place ledger-pruned         -type avx-api-integration:inflight-ledger

# Places (ADR-0003 failure semantics)

place controller-backoff       -type avx-api-integration:controller-backoff-state
place controller-degraded      -type avx-api-integration:controller-degraded-state
place endpoint-degraded        -type avx-api-integration:endpoint-degraded-state
place classified-response      -type avx-api-integration:api-requests
place fast-fail-reason         -type avx-api-integration:circuit-breaker
place dead-letter-record       -type avx-api-integration:security-events
place alert-row                -type avx-common:meta-attributes
place network-error-signal     -type avx-api-integration:circuit-breaker

# Places (ADR-0004 concurrency and session state)

place endpoint-lock       -type avx-api-integration:endpoint-serialisation-queue
place endpoint-waiter     -type avx-api-integration:endpoint-serialisation-queue
place session-state       -type avx-api-integration:session-state
place single-flight-lock  -type avx-api-integration:session-state

# Places (ADR-0005 cross-flow)

place validation-rejected-record -type avx-api-integration:security-events
place validated-records          -type avx-api-integration:api-requests
place first-fetch-buffer         -type avx-api-integration:api-requests

# Initial markings

init framework-request      {}
init session-state          {}
init controller-backoff     {}
init controller-degraded    {}
init endpoint-degraded      {}
init endpoint-lock          {}
init single-flight-lock     {}

# Transitions (ADR-0002 happy path)

transition receive-framework-request {
  out   {framework-request $req}
  label "Entry: framework request arrives"
}

transition validate-token {
  in    {framework-request req}
  out   {token-validated $req}
  label "Bearer token accepted"
}

transition ensure-session {
  in    {token-validated req} {session-state s}
  out   {session-available $s}
  label "Session identifier acquired or cached"
}

transition fetch-page {
  in    {session-available s}
  out   {controller-response $s}
  label "One Aviatrix page retrieved"
}

transition split-if-oversized {
  in    {controller-response page}
  out   {sub-batches $page}
  label "Split page to fit Data Collection Endpoint ceiling"
}

transition write-inflight-ledger {
  in    {sub-batches b}
  out   {ledger-written $b}
  label "Records recorded in ledger just before response"
}

transition dedup-filter {
  in    {ledger-written b}
  out   {deduplicated $b}
  label "Records already sent are suppressed"
}

transition normalise-response {
  in    {deduplicated b}
  out   {normalised $b}
  label "Collapse v2 envelope and v2.5 direct into one shape"
}

transition inject-correlation {
  in    {normalised b}
  out   {correlated $b}
  label "Add four standard metadata columns"
}

transition respond-to-framework {
  in    {correlated b}
  out   {response-sent $b}
  label "Write HTTP response"
}

# ADR-0006 removed await-http-complete (no such signal in Python v1
# Functions runtime). cursor-advance and prune-ledger now fire on
# response-sent, not response-completed.

transition advance-cursor {
  in    {response-sent b}
  out   {cursor-advanced $b}
  label "Per-endpoint cursor moves forward at response emission (ADR-0002 decision 1, retriggered per ADR-0006)"
}

transition prune-ledger {
  in    {ledger-written l}
  guard {local {$l(age) > $l(max-fold-age-seconds)}}
  out   {ledger-pruned $l}
  label "Ledger entries removed on any ledger touch where age > max-fold-age-seconds (ADR-0006)"
}

# Transitions (ADR-0003 failure semantics)

transition classify-response {
  in    {controller-response r}
  out   {classified-response $r}
  label "Branch into success, server, client, or data-level paths"
}

transition handle-5xx {
  in    {classified-response r}
  out   {controller-backoff $r}
  label "Server-transient: feed outer-loop backoff"
}

transition handle-429 {
  in    {classified-response r}
  out   {controller-backoff $r}
  label "Rate limit: respect Retry-After or fall back to max-backoff-ms"
}

transition handle-401-cached-session {
  in    {classified-response r} {session-state s}
  out   {session-available $s}
  label "Re-login once, retry once (ADR-0003 decision 3)"
}

transition handle-401-fresh-login {
  in    {classified-response r}
  out   {controller-degraded $r} {alert-row $r}
  label "Fresh-login 401 = credentials bad (controller-wide stop)"
}

transition handle-403 {
  in    {classified-response r}
  out   {controller-degraded $r} {alert-row $r}
  label "Authorization failure (controller-wide stop)"
}

transition handle-4xx-request {
  in    {classified-response r}
  out   {endpoint-degraded $r} {alert-row $r}
  label "400 or 404 (per-endpoint stop)"
}

transition mark-controller-degraded {
  in    {controller-degraded c}
  out   {controller-degraded $c}
  label "Set controller-wide degraded flag (fired by handle-401-fresh-login and handle-403)"
}

transition mark-endpoint-degraded {
  in    {endpoint-degraded e}
  out   {endpoint-degraded $e}
  label "Set per-endpoint degraded flag (fired by handle-4xx-request)"
}

transition handle-data-level {
  in    {classified-response r}
  out   {dead-letter-record $r}
  label "Record passed HTTP but failed processing"
}

transition inner-retry-network {
  in    {network-error-signal e}
  out   {network-error-signal $e}
  label "Inner-loop retry for transient network errors"
}

transition inner-retry-exhausted {
  in    {network-error-signal e}
  out   {controller-backoff $e}
  label "Hand off to outer-loop backoff after inner retries"
}

transition compute-next-backoff {
  in    {controller-backoff b}
  out   {controller-backoff $b}
  label "Advance the exponential schedule"
}

transition reset-backoff-on-success {
  in    {response-sent r} {controller-backoff b}
  out   {controller-backoff $b}
  label "Success zeroes out the backoff state (ADR-0006: fires on emission, not read completion)"
}

transition check-backoff-due {
  in    {framework-request req} {controller-backoff b}
  out   {framework-request $req}
  label "Gate incoming polls on next-attempt-due-timestamp"
}

transition fast-fail-to-framework {
  in    {framework-request req} {controller-backoff b}
  out   {fast-fail-reason $req}
  label "Return 503 when still in backoff window"
}

transition clear-endpoint-degraded-on-success {
  in    {response-sent r} {endpoint-degraded e}
  out   {endpoint-degraded $e}
  label "Recovery path (ADR-0003 decision 14; ADR-0006: response-sent trigger)"
}

transition clear-controller-degraded-on-success {
  in    {response-sent r} {controller-degraded c}
  out   {controller-degraded $c}
  label "Recovery path (ADR-0003 decision 14; ADR-0006: response-sent trigger)"
}

transition write-alert-row {
  in    {alert-row a}
  out   {alert-row $a}
  label "Emit meta event to Application Insights (ADR-0007 amendment of ADR-0003)"
}

transition dead-letter-to-app-insights {
  in    {dead-letter-record d}
  out   {dead-letter-record $d}
  label "Emit Application Insights event with record body"
}

# ADR-0006 folded age-out-ledger-entry into prune-ledger (the
# guard now governs the primary trigger, not a safety net).

# Transitions (ADR-0004 concurrency and session state machine)

transition acquire-endpoint-lock {
  in    {framework-request req} {endpoint-lock lock}
  out   {framework-request $req}
  label "Serialise per-endpoint polls"
}

transition release-endpoint-lock {
  in    {response-sent r} {endpoint-lock lock}
  out   {endpoint-lock $lock}
  label "Release on response emission (ADR-0006: response-sent trigger)"
}

transition drop-queued-request {
  in    {endpoint-waiter w}
  guard {local {$w(age) > 300}}
  out   {fast-fail-reason $w}
  label "Age-out queued waiters at max-queue-age-seconds"
}

transition check-session-state {
  in    {framework-request req} {session-state s}
  out   {framework-request $req}
  label "Dispatch by current-state"
}

transition transition-to-pending {
  in    {session-state s} {single-flight-lock lk}
  guard {local {$s(current-state) eq "unauthenticated" || $s(current-state) eq "denied"}}
  out   {session-state $s}
  label "Single-flight lock acquired; initiate login"
}

transition wait-for-pending-authentication {
  in    {framework-request req} {session-state s}
  guard {local {$s(current-state) eq "pending-authentication"}}
  out   {framework-request $req}
  label "Other requests block on the in-flight login"
}

transition transition-to-authenticated {
  in    {session-state s}
  out   {session-state $s}
  label "Login succeeded"
}

transition transition-to-denied {
  in    {session-state s}
  out   {session-state $s} {alert-row $s}
  label "Fresh-login 401 transitions to denied"
}

transition transition-to-unauthenticated-on-expiry {
  in    {session-state s}
  out   {session-state $s}
  label "401 on use clears cached session"
}

transition attempt-recovery-from-denied {
  in    {framework-request req} {session-state s}
  guard {local {$s(current-state) eq "denied"}}
  out   {framework-request $req}
  label "Next framework poll after denied attempts login again"
}

# Transitions (ADR-0005 cross-flow)

transition validate-against-yang-schema {
  in    {normalised b}
  out   {validated-records $b} {validation-rejected-record $b}
  label "YANG schema check before response"
}

transition reject-record-as-dead-letter {
  in    {validation-rejected-record r}
  out   {dead-letter-record $r}
  label "Invalid records route to Application Insights"
}

transition retry-fetch-after-relogin {
  in    {session-available s} {first-fetch-buffer buf}
  out   {controller-response $s}
  label "Re-fetch after mid-poll 401"
}

transition discard-first-fetch-buffer {
  in    {first-fetch-buffer buf}
  out   {first-fetch-buffer $buf}
  label "Second fetch wins; first is dropped"
}
