# =============================================================================
# Dual-provider run: read the intended policy from Infrahub, write Access
# Control rules to Cisco Firepower (FMC).
#
# VERIFIED: the FMC half (fmc_access_control_policy / fmc_security_zone /
# fmc_access_rules) was applied + destroyed against the live DevNet FMC sandbox
# with CiscoDevNet/fmc v2.4.0. The GraphQL the Infrahub data source wraps was
# verified against the live fw-cicd-demo branch.
#
# CONFIRM FOR YOUR BUILD: the exact attribute paths the *generated* infrahub
# provider exposes depend on your gql query → run
#   terraform providers schema -json | jq '.provider_schemas[].data_source_schemas'
# and adjust the `local.rules` extraction below to match. The field NAMES you
# need all come from gql/firewall_policy_rules.gql:
#   name, index, action(permit|deny), log, source_zone.name, destination_zone.name,
#   destination_address[].address (CIDR), destination_services[].port
# =============================================================================

# --- Read the policy from Infrahub (source of truth) ---------------------------
data "infrahub_firewall_policy_rules" "this" {
  policy = var.policy_name
}

# Normalize the data source into a simple list of rules. ADJUST the right-hand
# side to your generated schema (this mirrors the verified GraphQL shape).
locals {
  rules = [
    for r in data.infrahub_firewall_policy_rules.this.edges : {
      name     = r.node.name
      action   = lower(r.node.action) == "deny" ? "BLOCK" : "ALLOW"
      log      = try(r.node.log, false)
      src_zone = try(r.node.source_zone.name, null)
      dst_zone = try(r.node.destination_zone.name, null)
      dst_nets = [for a in try(r.node.destination_address, []) : a.address]
      # Infrahub services carry a port; protocol defaults to TCP (IANA 6).
      # Map from the service's ip_protocol relationship if you model it.
      dst_ports = [for s in try(r.node.destination_services, []) : { protocol = "6", port = tostring(s.port) }]
    }
  ]

  # Distinct zones referenced by the rules (FMC needs a zone object per name).
  zone_names = toset(compact(flatten([for r in local.rules : [r.src_zone, r.dst_zone]])))
}

# --- Supporting FMC objects ----------------------------------------------------
resource "fmc_security_zone" "zone" {
  for_each       = local.zone_names
  name           = each.value
  interface_type = "ROUTED"
}

resource "fmc_access_control_policy" "policy" {
  name           = "infrahub-${var.policy_name}"
  default_action = "BLOCK"
  manage_rules   = false # rules are owned by fmc_access_rules below
}

# --- The rules: one fmc_access_rules item per Infrahub rule --------------------
resource "fmc_access_rules" "rules" {
  access_control_policy_id = fmc_access_control_policy.policy.id

  items = [
    for r in local.rules : {
      name                 = r.name
      action               = r.action
      enabled              = true
      log_connection_begin = r.log
      send_events_to_fmc   = r.log

      source_zones      = r.src_zone == null ? [] : [{ id = fmc_security_zone.zone[r.src_zone].id }]
      destination_zones = r.dst_zone == null ? [] : [{ id = fmc_security_zone.zone[r.dst_zone].id }]

      destination_network_literals = [for cidr in r.dst_nets : { value = cidr }]
      destination_port_literals = [
        for p in r.dst_ports : { type = "PortLiteral", protocol = p.protocol, port = p.port }
      ]
    }
  ]
}

output "applied_policy" {
  value = fmc_access_control_policy.policy.name
}
