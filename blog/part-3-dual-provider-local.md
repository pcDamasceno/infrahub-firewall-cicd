# Part 3 — Dual-Provider Terraform: Infrahub → Cisco Firepower

*Network Automation for Security — Firewall Rules as Code, Part 3 of 5.*

[Part 1](./part-1-source-of-truth.md) made Infrahub the source of truth; [Part 2](./part-2-build-the-provider.md)
turned it into a Terraform **data source** served through Terralist. Now we close the loop:
**one `terraform apply` that reads the policy from Infrahub and writes Access Control rules to a
Cisco Firepower Management Center (FMC).** Two providers, one run — Infrahub on the read side,
`CiscoDevNet/fmc` on the write side.

> **What's verified here:** the FMC half — `fmc_access_control_policy`, `fmc_security_zone`,
> `fmc_access_rules` — was applied **and destroyed** against the live Cisco DevNet FMC sandbox
> (FMC 7.7.12) with `CiscoDevNet/fmc` **v2.4.0**, and the rule landed exactly as mapped. The
> Infrahub query was verified in Part 2. The one thing you'll confirm in *your* build is the
> attribute names your generated Infrahub provider exposes (more below).

> **FMC, not FDM.** This targets **FMC** (Firepower Management Center) and the official
> `CiscoDevNet/fmc` provider, which speaks the FMC API (`/api/fmc_config/v1/...`). A standalone
> **FTD managed by on-box FDM** is a *different* API and provider — `CiscoDevNet/fmc` won't manage
> it. If your sandbox is an FDM box, that's a different episode.

---

## The two providers

```hcl
# terraform/providers.tf
terraform {
  required_providers {
    infrahub = {                                   # built in Part 2, served via Terralist
      source  = "registry.example.com/netauto/infrahub"
      version = "~> 1.0"
    }
    fmc = {                                         # official, public registry
      source  = "CiscoDevNet/fmc"
      version = "~> 2.4"
    }
  }
}

provider "infrahub" {
  api_key         = var.infrahub_api_token
  infrahub_server = var.infrahub_server
  branch          = var.infrahub_branch
}

provider "fmc" {
  url      = var.fmc_url
  username = var.fmc_username
  password = var.fmc_password
  insecure = true   # sandbox self-signed cert
}
```

Secrets come from variables (`TF_VAR_*` env or a git-ignored `*.tfvars`) — never committed.

---

## Read side: the Infrahub data source

The `firewall_policy_rules` data source (from `gql/firewall_policy_rules.gql`) takes a policy name
and returns its rules. Against `edge-policy` it yields exactly what we modelled in Part 1:
`allow-inside-to-dmz-https` (permit, inside→dmz, `10.10.20.10/32`, tcp/443, log) and
`deny-outside-to-inside` (deny, outside→inside).

```hcl
data "infrahub_firewall_policy_rules" "this" {
  policy = var.policy_name   # "edge-policy"
}
```

> **Confirm the attribute paths for your build.** The *shape* the generated provider exposes
> depends on your query, so run
> `terraform providers schema -json | jq '.provider_schemas[].data_source_schemas'`
> and align the extraction below. The field **names** you need all come straight from the verified
> query: `name`, `action` (permit|deny), `log`, `source_zone.name`, `destination_zone.name`,
> `destination_address[].address` (CIDR), `destination_services[].port`.

---

## The mapping (Infrahub rule → FMC access rule)

This is the heart of the episode. A few translations matter:

| Infrahub | FMC (`fmc_access_rules` item) | Note |
|---|---|---|
| `action: permit` / `deny` | `action = "ALLOW"` / `"BLOCK"` | enum rename |
| `log: true` | `log_connection_begin` + `send_events_to_fmc` | |
| `source_zone.name` | `source_zones = [{ id = <zone id> }]` | zones referenced by **id**, so create/look up a zone object |
| `destination_address[].address` (`10.10.20.10/32`) | `destination_network_literals = [{ value = "..." }]` | literals — no need to pre-create network objects |
| `destination_services[].port` (`443`) | `destination_port_literals = [{ type="PortLiteral", protocol="6", port="443" }]` | **`protocol` is the IANA number** — TCP = `6`, not `"TCP"` |

```hcl
locals {
  rules = [
    for r in data.infrahub_firewall_policy_rules.this.edges : {
      name      = r.node.name
      action    = lower(r.node.action) == "deny" ? "BLOCK" : "ALLOW"
      log       = try(r.node.log, false)
      src_zone  = try(r.node.source_zone.name, null)
      dst_zone  = try(r.node.destination_zone.name, null)
      dst_nets  = [for a in try(r.node.destination_address, []) : a.address]
      dst_ports = [for s in try(r.node.destination_services, []) : { protocol = "6", port = tostring(s.port) }]
    }
  ]
  zone_names = toset(compact(flatten([for r in local.rules : [r.src_zone, r.dst_zone]])))
}

resource "fmc_security_zone" "zone" {
  for_each       = local.zone_names
  name           = each.value
  interface_type = "ROUTED"
}

resource "fmc_access_control_policy" "policy" {
  name           = "infrahub-${var.policy_name}"
  default_action = "BLOCK"
  manage_rules   = false   # rules owned by fmc_access_rules
}

resource "fmc_access_rules" "rules" {
  access_control_policy_id = fmc_access_control_policy.policy.id
  items = [
    for r in local.rules : {
      name                 = r.name
      action               = r.action
      enabled              = true
      log_connection_begin = r.log
      send_events_to_fmc   = r.log
      source_zones         = r.src_zone == null ? [] : [{ id = fmc_security_zone.zone[r.src_zone].id }]
      destination_zones    = r.dst_zone == null ? [] : [{ id = fmc_security_zone.zone[r.dst_zone].id }]
      destination_network_literals = [for cidr in r.dst_nets : { value = cidr }]
      destination_port_literals    = [for p in r.dst_ports : { type = "PortLiteral", protocol = p.protocol, port = p.port }]
    }
  ]
}
```

---

## Run it

```bash
cd terraform
export TF_VAR_infrahub_api_token=...   # never hardcode
export TF_VAR_fmc_password=...
terraform init      # pulls infrahub from Terralist + fmc from the public registry
terraform plan
terraform apply
```

The verified apply against the live sandbox (the rule built from `edge-policy`'s permit rule):

```text
fmc_access_control_policy.policy: Creating...
fmc_access_control_policy.policy: Creation complete after 3s [id=005056BF-...-060129645463]
fmc_access_rules.rules: Creating...
fmc_access_rules.rules: Creation complete after 1s [id=fd5eb5bb-...]
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
```

…and the rule as Terraform stored it — `action = "ALLOW"`, `value = "10.10.20.10/32"`,
`destination_port_literals = [{ port = "443", protocol = "6", type = "PortLiteral" }]`,
`log_connection_begin = true`. Edit a rule in Infrahub, `apply` again, and the access policy
follows.

---

## Gotchas worth knowing

- **`protocol` is the IANA number.** A port literal needs `type = "PortLiteral"` and
  `protocol = "6"` for TCP (`17` for UDP) — not the string `"TCP"`. `terraform validate` catches a
  missing `type`, but the protocol-number requirement only bites at apply.
- **DevNet FMC sandbox caps concurrent tokens.** If another session holds a token (a stray `curl`
  login, a parallel run), the provider's auth can fail with `Unable to create client … failed to
  retrieve FMC version: authentication failed, status code: 401`. Run Terraform with no other
  active token; the sandbox also rate-limits (~120 req/min, token ~30 min).
- **Shared sandbox.** It's full of other people's objects, so we create our **own**
  uniquely-named policy (`infrahub-edge-policy`) and zones rather than mutating shared ones.
- **Deploy ≠ create.** Creating rules via the API stages them in the policy; pushing them to a
  managed device is a separate **deploy** (`fmc_ftd_deploy`), which the shared sandbox typically
  can't do (no real managed device). On real FMC, add the deploy as the final step.
- **Zone names.** Infrahub uses `inside`/`outside`/`dmz`; a real FMC may already have differently
  named zones (e.g. `inside_zone`). Either align the names in Infrahub or look up existing zones
  with a `data "fmc_security_zone"` instead of creating them.

---

## Recap & what's next

We ran a single Terraform configuration that **read intended firewall policy from Infrahub and
wrote it to Cisco Firepower** — permit/deny, zones, networks, ports, logging, all sourced from the
data model. The FMC half is proven against a live FMC; the Infrahub half from the verified query.

In **[Part 4](./part-4-the-pipeline.md)** this stops being a laptop command: a **GitLab CI**
pipeline runs `init`/`plan`/`apply`, stores Terraform state in GitLab, posts the plan on the merge
request, and triggers on an **Infrahub webhook** when a policy change is merged — turning firewall
rules into reviewed, auto-deployed code.
