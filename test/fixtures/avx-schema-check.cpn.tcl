# arch/action-models/avx-schema-check.cpn.tcl
#
# Behaviour of the timer-triggered schema-check Azure Function.
# Realises ADR-0005 decision 4 (periodic schema reaffirmation) as
# narrowed by ADR-0008: drift detection in adapter input contracts,
# alerts to Application Insights, no auto-applied table evolution
# (the canonical AviatrixEvent_CL table has a fixed schema with a
# dynamic Attributes column per ADR-0007).

cpn-spec 1.0

yang import avx-api-integration
yang import avx-azure
yang import avx-common
yang import avx-data-transformation

# Places

place timer-tick            -type avx-api-integration:schema-check-state
place startup-signal        -type avx-api-integration:schema-check-state
place controller-schema     -type avx-data-transformation:schema-evolution
place stored-schema-hash    -type avx-api-integration:schema-check-state
place drift-event           -type avx-data-transformation:schema-evolution
place alert-row             -type avx-common:meta-attributes

init timer-tick     {}
init startup-signal {}

# Transitions

transition fire-startup {
  in    {startup-signal s}
  out   {controller-schema $s}
  label "Fires once at Function App instance startup"
}

transition fire-four-hourly {
  in    {timer-tick t}
  out   {controller-schema $t}
  label "Fires every four hours on timer trigger"
}

transition fetch-controller-schema {
  in    {controller-schema cs}
  out   {controller-schema $cs}
  label "Canary-fetch to infer current controller schema"
}

transition compute-schema-hash {
  in    {controller-schema cs}
  out   {stored-schema-hash $cs}
  label "Canonical JSON then SHA-256"
}

transition compare-with-stored-hash {
  in    {stored-schema-hash h}
  out   {drift-event $h}
  label "Non-empty drift list on mismatch; empty otherwise"
}

transition write-drift-alert {
  in    {drift-event d}
  out   {alert-row $d}
  label "Meta event to Application Insights with FailureKind schema-drift (ADR-0007 amendment of ADR-0003)"
}

transition alarm-on-field-removed {
  in    {drift-event d}
  out   {alert-row $d}
  label "Field-removed drift is alarmed; the canonical table is unchanged (ADR-0008)"
}

transition alarm-on-field-type-changed {
  in    {drift-event d}
  out   {alert-row $d}
  label "Field-type-change drift is alarmed; the canonical table is unchanged (ADR-0008)"
}
