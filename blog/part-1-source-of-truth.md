# Firewall Rules as Code — Part 1: The Source of Truth

*Network Automation for Security, Part 1 of 5*

If you already live in Git, CI/CD, and Terraform, you know the pattern: declare the desired state, review it like code, let a pipeline reconcile reality. Network security is the last place that pattern usually reaches. Firewall rules still get clicked into a GUI, copied between change tickets, and discovered after the fact. This series fixes that for **Cisco Firepower**, with **Infrahub** as the source of truth.

This first post is the foundation. We load a security data model into Infrahub and model a real (small) edge policy as objects — on a branch, reviewed like a PR. No Terraform yet. By the end you'll have queryable, related, branchable firewall policy living in Infrahub, ready for Part 2 to read.

## The series

1. **The source of truth** *(this post)* — load the security schema into Infrahub, model an example policy.
2. **Build your own Infrahub Terraform provider** — generate it from GraphQL, publish to a GitLab registry.
3. **Dual-provider Terraform** — read intended policy from Infrahub, write Access Control rules to Cisco Firepower via `CiscoDevNet/fmc`.
4. **The pipeline** — GitLab CI + an Infrahub webhook + remote state + plan-on-MR.
5. **Firewall rules as code** — the full day-2 demo.

The end-state architecture:

```
Engineer edits policy ─► Infrahub (security schema = source of truth)
        │  branch + proposed change + merge
        ▼
   Infrahub webhook ─► GitLab CI pipeline
        │
        ▼
   Terraform run:
     • infrahub provider (DATA SOURCE) ← reads intended policy   [served from GitLab registry]
     • CiscoDevNet/fmc   (RESOURCE)    → writes ACP rules to FMC  [public registry]
     • state in GitLab; plan posted to the MR
        ▼
   Cisco Firepower (DevNet/dCloud sandbox FMC)
```

Everything downstream depends on the model we build today.

## Why a data model, not config templates

The reflex for "firewall rules as code" is to template the device config — Jinja into FMC API calls, or HCL straight to the appliance. That works until you ask a question the template can't answer:

- *Which rules reference this host?* Grep across templates and hope naming is consistent.
- *What changed between last week and now, and who approved it?* Diff text blobs.
- *Is this service object used anywhere before I delete it?* Good luck.

Infrahub treats policy as **a graph of typed objects with relationships**, not text. A rule is a node that *relates to* a zone, an address, a service. That buys you four things templates never will:

- **Queryable** — "every rule whose destination is `web-server-01`" is a graph query, not a grep.
- **Related** — delete-protection and reuse fall out of the relationships; a service object is shared, not copy-pasted.
- **Branchable** — Infrahub branches the whole dataset, so you propose a change on a branch and merge it.
- **Reviewable** — a proposed change is reviewed and approved in the UI before it ever touches a device.

That last pair is the whole point of this series: the firewall's running config becomes a *projection* of an approved, version-controlled intent.

## Tour of the security schema

The schema we load (`schemas/security.yml`) is vendored from the OpsMill schema-library `experimental/security/`. It models firewall policy as a small set of kinds. The ones that matter for this post:

- **`SecurityPolicy`** — a named container for an ordered set of rules.
- **`SecurityPolicyRule`** — the heart of the model. Attributes: `index` (order), `name`, `action` (`permit` | `deny`), `log`. Relationships: `policy` (the parent), `source_zone` / `destination_zone`, `source_address` / `destination_address` (many), `source_services` / `destination_services` (many). Each rule resolves into a `SecurityRenderedPolicyRule` — the flattened, device-facing form a downstream provider consumes.
- **`SecurityZone`** — inside / outside / dmz, etc.
- **`SecurityIPAddress`** — a host or network object (e.g. `10.10.20.10/32`).
- **`SecurityService`** — a port/protocol object (e.g. tcp/443).
- **Address & service groups** — reusable bundles of the above.
- **`SecurityFirewall`** — the device itself. It inherits a stack of generics: `DcimGenericDevice` + `DcimPhysicalDevice` + `CoreArtifactTarget` + `SecurityPolicyAssignment`. That inheritance is *why* the security schema can't load alone — it depends on the DCIM base schema (more on that below).

A detail that becomes load-critical later: the address and service relationships don't point at `SecurityIPAddress` / `SecurityService` directly. They point at the **abstract generic kinds** `SecurityGenericAddress` and `SecurityGenericService`. `SecurityIPAddress` is one concrete implementation of `SecurityGenericAddress`; an address *group* or an IPAM prefix is another. The relationship is to the abstraction. Hold that thought — it's the gotcha in step "Model the policy."

## Setup

The repo is self-contained. Python 3.12, [`uv`](https://docs.astral.sh/uv/) for the environment, and a `pyproject.toml` that pins the Infrahub SDK:

```toml
[project]
name = "infrahub-firewall-cicd"
requires-python = ">=3.10,<3.13"
dependencies = [
    "infrahub-sdk[all]>=1.17.0",
]
```

Sync the environment and confirm the toolchain:

```bash
uv sync
uv run infrahubctl version
# Python SDK: v1.21.0
```

We're targeting **Infrahub 1.9.3** with **infrahub-sdk / infrahubctl v1.21.0**.

### Auth and secrets — read this before you run anything

`infrahubctl` needs to know *where* your Infrahub is and *how* to authenticate. Two equivalent ways:

**Config file** (recommended — keeps the demo commands clean). Create `infrahubctl.toml`:

```toml
server_address = "https://your-infrahub.example.com"
api_token      = "<your-api-token>"
```

Point the CLI (and our `verify.py`) at it:

```bash
export INFRAHUBCTL_CONFIG="$PWD/infrahubctl.toml"
```

**Environment variables** (handy for CI):

```bash
export INFRAHUB_ADDRESS="https://your-infrahub.example.com"
export INFRAHUB_API_TOKEN="<your-api-token>"
```

> **Secrets discipline.** Never commit the token or your real instance host. The repo `.gitignore` already blocks `infrahubctl.toml`, `.env`, and `*.tfvars` so a careless `git add .` can't leak them. In Part 4 these credentials live as **masked + protected** GitLab CI variables — never in tracked files. Use `https://your-infrahub.example.com` as a stand-in for your own URL throughout.

Confirm the connection before doing anything destructive:

```bash
uv run infrahubctl info
# Connection Status: OK
# User: Admin
```

## A branch, not main

Infrahub branches the *entire dataset*, schema included. So we mirror the Git PR flow: do all of this work on a feature branch, review it, then merge it into `main` in the UI. Nothing here touches `main` directly, which means everything is reviewable and reversible.

```bash
uv run infrahubctl branch create fw-cicd-demo
# Branch 'fw-cicd-demo' created (off main)
```

Every command from here carries `--branch fw-cicd-demo`. When you're happy, you merge `fw-cicd-demo` into `main` from the Infrahub UI — exactly like approving and merging a pull request.

## Load the schema

**Order matters.** The security schema inherits from DCIM (`SecurityFirewall` is also a `DcimPhysicalDevice`), and DCIM in turn references location and IPAM. So the base schemas go in first, in dependency order — location, IPAM, then DCIM — and only then the security schema on top.

```bash
uv run infrahubctl schema load \
  base/location.yml base/ipam.yml base/dcim.yml \
  --branch fw-cicd-demo --wait 30
# 3 schemas processed ... Schema updated on all workers.
```

Now the security schema:

```bash
uv run infrahubctl schema load schemas/security.yml \
  --branch fw-cicd-demo --wait 30
```

`--wait 30` blocks until every worker has the new schema, so the next command can't race ahead of an un-migrated node.

Confirm it took. `schema check` compares your file against what's already loaded on the branch:

```bash
uv run infrahubctl schema check schemas/security.yml \
  --branch fw-cicd-demo
# schemas/security.yml is Valid!
```

The check reports **no pending Security additions** — which is exactly what "already loaded" looks like. If it instead listed a pile of nodes to add, the load hadn't landed.

## Model the policy

With the schema in place, we describe the policy as **object files** in `data/`. They're numbered to load in dependency order: zones and addresses and services first, then the policy, then the rules that wire everything together, then the firewall.

The object-file format is a thin envelope around a list of objects:

```yaml
---
apiVersion: infrahub.app/v1
kind: Object
spec:
  kind: SecurityZone
  data:
    - name: inside
    - name: outside
    - name: dmz
```

The policy we're modeling:

- **Zones** (`data/00-zones.yml`): `inside`, `outside`, `dmz`.
- **Addresses** (`data/10-addresses.yml`): `web-server-01` = `10.10.20.10/32`, `admin-host` = `10.10.10.5/32`.
- **Services** (`data/20-services.yml`): `https` = 443, `ssh` = 22.
- **Policy** (`data/30-policy.yml`): `edge-policy`.
- **Rules** (`data/40-rules.yml`):
  - `allow-inside-to-dmz-https` — index 10, `permit`, `log`, source zone `inside` → dest zone `dmz`, dest address `web-server-01`, dest service `https`.
  - `deny-outside-to-inside` — index 20, `deny`, `log`, source zone `outside` → dest zone `inside`.
- **Firewall** (`data/50-firewall.yml`): `ftd-edge-01` — role `edge_firewall`, status `active`, location `site_100`, policy `edge-policy`.

Each file gets validated, then loaded, on the branch:

```bash
uv run infrahubctl object validate data/00-zones.yml --branch fw-cicd-demo
uv run infrahubctl object load     data/00-zones.yml --branch fw-cicd-demo
```

### Cardinality-one relationships: just use the name

For a relationship to a *single* peer, you reference it with a bare human-friendly id (hfid) — usually its `name`. This is clean and works everywhere:

```yaml
policy: edge-policy        # SecurityPolicyRule → SecurityPolicy (one)
source_zone: inside        # → SecurityZone (one)
location: site_100         # SecurityFirewall → location (one)
```

Infrahub resolves `edge-policy` to the one `SecurityPolicy` with that name. Done.

> ### The gotcha: many-relationships to an *abstract* peer
>
> Here's the one that will bite you. A cardinality-**many** relationship whose peer kind is **abstract/generic** *cannot* be referenced by a bare hfid list. Recall from the schema tour: `destination_address` points at `SecurityGenericAddress`, and `destination_services` points at `SecurityGenericService` — both abstract.
>
> So the obvious form:
>
> ```yaml
> destination_address: [web-server-01]      # tempting — and broken
> destination_services: [https]
> ```
>
> **passes `object validate`** but **fails at `object load`** with:
>
> ```
> Unable to find the node ... / SecurityGenericService
> ```
>
> Why? An hfid is resolved *against a kind*. When the peer is an abstract generic, the server has no concrete table to look the name up in — `web-server-01` could be a `SecurityIPAddress`, a prefix, or a group. It can't pick one, so the lookup fails. Validation only checks shape, not resolvability, which is why it slips past `validate` and only blows up on `load`.
>
> The load-safe form names the **concrete kind** explicitly and supplies the data inline:
>
> ```yaml
> destination_address:
>   - kind: SecurityIPAddress
>     data:
>       name: web-server-01
>       address: 10.10.20.10/32
> destination_services:
>   - kind: SecurityService
>     data:
>       name: https
>       port: 443
> ```
>
> Now the server knows *exactly* which kind to resolve against. And because `name` is a uniqueness constraint, this is **idempotent** — the address already created in `data/10-addresses.yml` is matched, not duplicated. No second `web-server-01` appears.
>
> The pattern generalizes: **any time a many-relationship's peer is an abstract generic, use the explicit `kind` + `data` block.** When you meet another abstract peer in the schema, you'll recognize the symptom (validate-passes / load-fails) and reach for the same fix.

So the real `data/40-rules.yml` looks like this:

```yaml
---
apiVersion: infrahub.app/v1
kind: Object
spec:
  kind: SecurityPolicyRule
  data:
    - name: allow-inside-to-dmz-https
      index: 10
      action: permit
      log: true
      policy: edge-policy
      source_zone: inside
      destination_zone: dmz
      destination_address:
        - kind: SecurityIPAddress
          data:
            name: web-server-01
            address: 10.10.20.10/32
      destination_services:
        - kind: SecurityService
          data:
            name: https
            port: 443
    - name: deny-outside-to-inside
      index: 20
      action: deny
      log: true
      policy: edge-policy
      source_zone: outside
      destination_zone: inside
```

Note the cardinality-one relationships (`policy`, `source_zone`, `destination_zone`) stay as bare hfids — only the abstract-peer many-relationships need the verbose form.

Load everything in order. The repo wraps this in a `make` target:

```bash
make load-data BRANCH=fw-cicd-demo
```

which expands to a single `object load` over all six files:

```bash
uv run infrahubctl object load \
  data/00-zones.yml data/10-addresses.yml data/20-services.yml \
  data/30-policy.yml data/40-rules.yml data/50-firewall.yml \
  --branch fw-cicd-demo
```

## Verify

You'd expect `infrahubctl graphql --query ...` for a quick count — but **there's no `graphql` subcommand**. Instead, a tiny script uses the Python SDK and reads the *same* config you set up earlier (`INFRAHUBCTL_CONFIG`), so there are still no secrets in the code:

```python
"""Print counts of the Security objects loaded on the demo branch."""
import os
import toml
from infrahub_sdk import InfrahubClientSync, Config

cfg = toml.load(os.environ["INFRAHUBCTL_CONFIG"])
client = InfrahubClientSync(config=Config(
    address=cfg["server_address"], api_token=cfg["api_token"]))
branch = os.environ.get("INFRAHUB_BRANCH", "fw-cicd-demo")

for kind in [
    "SecurityZone", "SecurityIPAddress", "SecurityService",
    "SecurityPolicy", "SecurityPolicyRule", "SecurityFirewall",
]:
    print(f"{kind}: {len(client.all(kind, branch=branch))}")
```

Run it through the `make verify` target:

```bash
make verify BRANCH=fw-cicd-demo
```

Real output:

```
SecurityZone: 3
SecurityIPAddress: 2
SecurityService: 2
SecurityPolicy: 1
SecurityPolicyRule: 2
SecurityFirewall: 1
```

Three zones, two addresses, two services, one policy, two rules, one firewall — exactly what we modeled, and no duplicate addresses or services despite naming them again inside the rule. The inline `kind` + `data` blocks resolved against the objects we already created.

Now open the Infrahub UI, switch to the `fw-cicd-demo` branch, and browse it: click into `edge-policy`, follow its rules, see `allow-inside-to-dmz-https` linked to the `dmz` zone, the `web-server-01` host, and the `https` service. This is the "related, queryable" payoff from the top of the post — and it's all on a branch you can review and merge like a PR.

## Recap + what's next

We loaded a real security data model into Infrahub (base schemas first, in dependency order, then security), modeled an edge policy as object files on a reviewable branch, dodged the abstract-peer load gotcha, and verified the result with the SDK. Firewall policy is now **queryable, related, branchable, and reviewable** — the source of truth.

In **Part 2** we make this model *usable by Terraform*. We'll write a GraphQL query against the security schema, generate a custom Infrahub Terraform provider from it, and publish that provider to a GitLab registry — turning today's objects into a Terraform data source we can plan against. See you there.
