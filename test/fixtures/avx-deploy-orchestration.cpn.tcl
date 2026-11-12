# arch/action-models/avx-deploy-orchestration.cpn.tcl
#
# Behaviour of the test-environment deploy orchestrator per ADR-0010.
#
# A single deploy-progress-token flows through the net. Its location
# names the deploy phase. The orchestrator persists the token's place
# durably, separate from terraform.tfstate (which tracks resource
# existence, not deploy phase).
#
# Each forward transition has an action (a terraform target, an
# Azure Resource Manager deployment, or an az / curl call) and a
# readiness predicate that gates entry to the destination place. The
# orchestrator does not produce the output token until the predicate
# is satisfied, polling under a defined backoff. The retry / backoff
# policy is held by the orchestrator, not by the net; the net says
# only "either the gate was met (advance) or the budget ran out
# (fail)".
#
# Failure transitions route the token to a single sink place
# (`failed`). Recovery from `failed` is operator-initiated, not
# automatic, so no transitions leave it.

cpn-spec 1.0

yang import avx-deployment-validation

# Places — one per deploy phase. Names match the enum values in
# avx-deployment-validation:deploy-phase.

place bootstrap                   -type avx-deployment-validation:deploy-progress-token
place rg-created                  -type avx-deployment-validation:deploy-progress-token
place controller-vm-provisioned   -type avx-deployment-validation:deploy-progress-token
place controller-api-ready        -type avx-deployment-validation:deploy-progress-token
place controller-login-ok         -type avx-deployment-validation:deploy-progress-token
place aviatrix-account-onboarded  -type avx-deployment-validation:deploy-progress-token
place network-deployed            -type avx-deployment-validation:deploy-progress-token
place function-app-deployed       -type avx-deployment-validation:deploy-progress-token
place function-app-warm           -type avx-deployment-validation:deploy-progress-token
place connectors-validated        -type avx-deployment-validation:deploy-progress-token
place dcr-ingesting               -type avx-deployment-validation:deploy-progress-token
place adr-0009-verified           -type avx-deployment-validation:deploy-progress-token
place failed                      -type avx-deployment-validation:deploy-progress-token

init bootstrap {}

# Forward transitions.

transition create-rg {
  in    {bootstrap t}
  out   {rg-created $t}
  guard {shell "az group show --name <prefix>-rg succeeds"}
  label "Action: terraform apply -target=module.controller.azurerm_resource_group.main. Gate: resource group present in Azure."
}

transition provision-controller-vm {
  in    {rg-created t}
  out   {controller-vm-provisioned $t}
  guard {shell "azurerm_linux_virtual_machine.controller in power state Running"}
  label "Action: terraform apply -target=module.controller (full). Gate: controller VM Running, public IP allocated."
}

transition await-controller-api {
  in    {controller-vm-provisioned t}
  out   {controller-api-ready $t}
  guard {http "HTTPS GET <controller-pip>/v1/api returns 200 within backoff"}
  label "Closes part of the failure class described in ADR-0010 context (2): VM Running is not API ready. No progression until the controller's API endpoint actually answers."
}

transition controller-login {
  in    {controller-api-ready t}
  out   {controller-login-ok $t}
  guard {http "POST /v1/api?action=login with admin credentials returns a CID"}
  label "API reachable is not API ready. Gate: an admin login round-trip succeeds end-to-end. This is the predicate the gateway-launch RPC requires; gating here is what is expected to retire the gateway DEADLINE_EXCEEDED symptom."
}

transition onboard-aviatrix-account {
  in    {controller-login-ok t}
  out   {aviatrix-account-onboarded $t}
  guard {http "list_cloud_accounts on the controller contains the configured account name"}
  label "Action: terraform apply -target=module.network.aviatrix_account.azure. Gate: the access account is registered on the controller."
}

transition deploy-network {
  in    {aviatrix-account-onboarded t}
  out   {network-deployed $t}
  guard {http "transit and the three spoke gateways report state up; DCF and FQDN policies report applied"}
  label "Action: terraform apply -target=module.network. Gate: gateways report 'up' on the controller, not merely 'launched in terraform'."
}

transition deploy-function-app {
  in    {network-deployed t}
  out   {function-app-deployed $t}
  guard {shell "Function App resource exists with WEBSITE_RUN_FROM_PACKAGE set to the content-hash blob URL"}
  label "Action: terraform apply for the Function App resources prior to the connector Azure Resource Manager template. Gate: the FA resource exists and is wired to its code package."
}

transition warm-function-app {
  in    {function-app-deployed t}
  out   {function-app-warm $t}
  guard {http "HTTPS GET <fa>/api/proxy/health with the connectorToken bearer returns HTTP 200 within backoff"}
  label "Closes the failure class described in ADR-0010 context (1). The probe must exercise the same auth path the dataConnectors will use, so it carries the same bearer the dataConnectors carry and accepts only HTTP 200 — anything else (401, 404, 5xx) means the contract is not yet served, including the controller-session initialization in ADR-0004. In the shipped marketplace template this guard manifests as a Microsoft.Resources/deploymentScripts resource that reads the bearer from Key Vault, probes the proxy, and is dependsOn'd by the ten dataConnectors."
}

transition validate-connectors {
  in    {function-app-warm t}
  out   {connectors-validated $t}
  guard {shell "all ten dataConnectors reach Succeeded provisioning state"}
  label "Action: terraform apply for module.sentinel.azurerm_resource_group_template_deployment.aviatrix_connector. Gate: every Codeless Connector Framework probe passed."
}

transition await-ingestion {
  in    {connectors-validated t}
  out   {dcr-ingesting $t}
  guard {shell "AviatrixEvent_CL has at least one row per canonical EventClass within ingestion-latency window"}
  label "Gate: data is actually flowing, not merely provisioned. Provisioned + zero rows is a failure mode the gate must catch."
}

transition verify-adr-0009 {
  in    {dcr-ingesting t}
  out   {adr-0009-verified $t}
  guard {shell "ten dataConnectors active and ingesting under the ARM-resolved bearer; no 401s observed on the proxy from Sentinel sources"}
  label "Accept state. ADR-0009 confirmed end-to-end."
}

# Failure transitions — one paired sink per forward transition. The
# guard is the orchestrator's retry-budget-exhausted signal; the net
# itself does not encode retry counts (those live on the
# deploy-progress-token's attempt-count-in-phase leaf).

transition fail-create-rg {
  in    {bootstrap t}
  out   {failed $t}
  guard {retry create-rg}
  label "Failure sink for create-rg."
}

transition fail-provision-controller-vm {
  in    {rg-created t}
  out   {failed $t}
  guard {retry provision-controller-vm}
  label "Failure sink for provision-controller-vm."
}

transition fail-await-controller-api {
  in    {controller-vm-provisioned t}
  out   {failed $t}
  guard {retry await-controller-api}
  label "Failure sink for await-controller-api."
}

transition fail-controller-login {
  in    {controller-api-ready t}
  out   {failed $t}
  guard {retry controller-login}
  label "Failure sink for controller-login."
}

transition fail-onboard-aviatrix-account {
  in    {controller-login-ok t}
  out   {failed $t}
  guard {retry onboard-aviatrix-account}
  label "Failure sink for onboard-aviatrix-account."
}

transition fail-deploy-network {
  in    {aviatrix-account-onboarded t}
  out   {failed $t}
  guard {retry deploy-network}
  label "Failure sink for deploy-network."
}

transition fail-deploy-function-app {
  in    {network-deployed t}
  out   {failed $t}
  guard {retry deploy-function-app}
  label "Failure sink for deploy-function-app."
}

transition fail-warm-function-app {
  in    {function-app-deployed t}
  out   {failed $t}
  guard {retry warm-function-app}
  label "Failure sink for warm-function-app."
}

transition fail-validate-connectors {
  in    {function-app-warm t}
  out   {failed $t}
  guard {retry validate-connectors}
  label "Failure sink for validate-connectors."
}

transition fail-await-ingestion {
  in    {connectors-validated t}
  out   {failed $t}
  guard {retry await-ingestion}
  label "Failure sink for await-ingestion."
}

transition fail-verify-adr-0009 {
  in    {dcr-ingesting t}
  out   {failed $t}
  guard {retry verify-adr-0009}
  label "Failure sink for verify-adr-0009."
}
