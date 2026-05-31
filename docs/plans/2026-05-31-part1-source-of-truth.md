# Part 1 — The Source of Truth — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load the `security.yml` schema into the live Infrahub instance and model a reproducible example firewall policy (zones, addresses, services, a permit + a deny rule, a firewall device) as committed `infrahubctl` object files, then write the Part 1 blog post.

**Architecture:** The new `infrahub-firewall-cicd` repo becomes self-contained: a minimal `pyproject.toml` pins `infrahub-sdk` so `uv run infrahubctl` works inside it. Credentials come from environment variables (`INFRAHUB_ADDRESS`, `INFRAHUB_API_TOKEN`) — never committed. Example data lives in `data/` as numbered object files so relationships load in dependency order (zones/addresses/services → policy → rules → firewall).

**Tech Stack:** Infrahub + `infrahub-sdk`/`infrahubctl`, `uv`, YAML object files, Markdown.

**Decomposition note:** This is the first of five sequential plans (one per series part). Parts 2–5 are roadmapped at the end of this document with goals and acceptance criteria; each gets its own fully-detailed plan written just-in-time, because Parts 2–5 depend on live-system work and the two validation spikes (GitLab-as-provider-registry; rule-rendering approach) whose exact commands cannot be honestly written before those spikes resolve.

**Live-instance execution decisions (confirmed with user):**
- **Auth:** reuse the existing config at `/home/pdamasceno/GIT/docker/schema-library/infrahubctl.toml`
  (holds `server_address` + `api_token`) via `export INFRAHUBCTL_CONFIG=/home/pdamasceno/GIT/docker/schema-library/infrahubctl.toml`.
  Never echo, copy, or commit the token. (Rotation deferred by user; still recommended before publishing.)
- **Target:** all schema + data loads go to a dedicated Infrahub branch **`fw-cicd-demo`**, NOT `main`.
  The user reviews in the UI and merges to main themselves. This makes every load reversible.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `pyproject.toml` | Pin `infrahub-sdk[all]` so `uv run infrahubctl` runs inside this repo |
| `schemas/security.yml` | Local copy of the security schema loaded in Part 1 (vendored from `schema-library/experimental/security/`) |
| `data/00-zones.yml` | Security zones (inside, outside, dmz) |
| `data/10-addresses.yml` | IP addresses / prefixes used by rules |
| `data/20-services.yml` | Services / ports (e.g. https, ssh) |
| `data/30-policy.yml` | The `SecurityPolicy` object |
| `data/40-rules.yml` | `SecurityPolicyRule` objects (one permit, one deny) referencing the above |
| `data/50-firewall.yml` | `SecurityFirewall` device bound to the policy |
| `verify.py` | SDK script that prints counts of loaded Security objects (used by `make verify`) |
| `blog/part-1-source-of-truth.md` | The Part 1 post |
| `Makefile` | Convenience targets: `make load-schema`, `make load-data`, `make verify` |

---

## Task 1: Make the repo self-contained for `infrahubctl`

**Files:**
- Create: `pyproject.toml`

- [ ] **Step 1: Create `pyproject.toml`**

```toml
[project]
name = "infrahub-firewall-cicd"
version = "0.1.0"
description = "Firewall rules as code with Infrahub, Terraform & GitLab"
requires-python = ">=3.10,<3.13"
dependencies = [
    "infrahub-sdk[all]>=1.17.0",
]
```

- [ ] **Step 2: Resolve the environment**

Run: `cd /home/pdamasceno/GIT/docker/infrahub-firewall-cicd && uv sync`
Expected: a `.uv`/virtualenv is created and `infrahub-sdk` installs without error.

- [ ] **Step 3: Verify `infrahubctl` runs in this repo**

Run: `uv run infrahubctl version`
Expected: prints Python SDK + Python version, no traceback.

- [ ] **Step 4: Commit**

```bash
git add pyproject.toml uv.lock
git commit -m "chore: pin infrahub-sdk so infrahubctl runs in-repo"
```

---

## Task 2: Verify connectivity to the live instance via env vars (no committed secrets)

**Files:** none (environment only)

- [ ] **Step 1: Point infrahubctl at the existing config (no secret handling)**

```bash
export INFRAHUBCTL_CONFIG=/home/pdamasceno/GIT/docker/schema-library/infrahubctl.toml
```
This file already holds `server_address` + `api_token`. Do not print, copy, or commit it.

- [ ] **Step 2: Confirm the SDK can reach the instance**

Run: `uv run infrahubctl info`
Expected: shows the configured address `https://infrahub.autonetops.com` and a successful status (no auth/connection error).

- [ ] **Step 3: Confirm `infrahubctl.toml` is git-ignored**

Run: `git check-ignore infrahubctl.toml && echo IGNORED`
Expected: prints `infrahubctl.toml` then `IGNORED` (so a future config file can't be committed).

> No commit — this task only validates connectivity.

---

## Task 3: Confirm base-schema dependencies exist on the instance

The security schema inherits from / references `DcimGenericDevice`, `DcimPhysicalDevice`,
`DcimInterface`, `DcimEndpoint`, `IpamIPAddress`, `IpamPrefix`, `LocationGeneric`,
`CoreArtifactTarget`. These must already be present before `security.yml` will load.

**Files:** none (branch creation + instance-side schema verification)

- [ ] **Step 1: Create the dedicated demo branch**

Run: `uv run infrahubctl branch create fw-cicd-demo`
Expected: branch `fw-cicd-demo` created (or already exists — fine to reuse). All later loads target this branch.

- [ ] **Step 2: Ensure base-schema dependencies are present on the branch (idempotent)**

The security schema inherits from `DcimGenericDevice`/`DcimPhysicalDevice`/`DcimInterface`/`DcimEndpoint`,
`IpamIPAddress`/`IpamPrefix`, `LocationGeneric`, `CoreArtifactTarget`. Load the base schemas into the
branch — this is a no-op diff if they already exist on `main` (branches inherit from main), and it
guarantees the security schema will load. Order matters: location + ipam before dcim.

Run:
```bash
SL=/home/pdamasceno/GIT/docker/schema-library
uv run infrahubctl schema load $SL/base/location.yml $SL/base/ipam.yml $SL/base/dcim.yml \
  --branch fw-cicd-demo --wait 30
```
Expected: load reports success / converged (or "no changes").

> No git commit — branch creation + instance-side schema load only.

---

## Task 4: Vendor the security schema and load it

**Files:**
- Create: `schemas/security.yml` (copy of `schema-library/experimental/security/security.yml`)

- [ ] **Step 1: Vendor the schema into this repo**

Run:
```bash
mkdir -p schemas
cp /home/pdamasceno/GIT/docker/schema-library/experimental/security/security.yml schemas/security.yml
```
Expected: `schemas/security.yml` exists and is identical to the source.

- [ ] **Step 2: Load the schema into the demo branch**

Run: `uv run infrahubctl schema load schemas/security.yml --branch fw-cicd-demo --wait 30`
Expected: the branch reports the security kinds added / converged (proves base deps from Task 3 are satisfied). If it fails with a missing-kind error, return to Task 3.

- [ ] **Step 3: Confirm the schema is loaded on the branch**

Run: `uv run infrahubctl schema check schemas/security.yml --branch fw-cicd-demo`
Expected: reports no changes / already in sync (proving the schema is present on the branch). If
`schema check` instead reports it *would* add the kinds, the Step 2 load did not take — re-run it.

- [ ] **Step 5: Commit**

```bash
git add schemas/security.yml
git commit -m "feat(schema): vendor and document the security schema"
```

---

## Task 5: Author and load the example data — zones, addresses, services

**Files:**
- Create: `data/00-zones.yml`, `data/10-addresses.yml`, `data/20-services.yml`

> Object-file format note: confirm the exact shape with `infrahubctl object validate` (Step 2)
> before loading. The template below follows the infrahub-sdk object-file convention.

- [ ] **Step 1: Write `data/00-zones.yml`**

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

- [ ] **Step 2: Validate the object file**

Run: `uv run infrahubctl object validate data/00-zones.yml --branch fw-cicd-demo`
Expected: reports valid. (Validate on the demo branch — the `Security*` schema lives there, not on
main.) If the format is rejected, adjust to the version the validator expects (it names the error),
then re-run until valid.

- [ ] **Step 3: Write `data/10-addresses.yml`**

```yaml
---
apiVersion: infrahub.app/v1
kind: Object
spec:
  kind: SecurityIPAddress
  data:
    - name: web-server-01
      address: 10.10.20.10/32
      description: "DMZ web server"
    - name: admin-host
      address: 10.10.10.5/32
      description: "Inside admin workstation"
```

- [ ] **Step 4: Write `data/20-services.yml`**

```yaml
---
apiVersion: infrahub.app/v1
kind: Object
spec:
  kind: SecurityService
  data:
    - name: https
      port: 443
    - name: ssh
      port: 22
```

- [ ] **Step 5: Validate both new files**

Run: `uv run infrahubctl object validate data/10-addresses.yml data/20-services.yml --branch fw-cicd-demo`
Expected: both valid.

- [ ] **Step 6: Load zones, addresses, services into the demo branch**

Run: `uv run infrahubctl object load data/00-zones.yml data/10-addresses.yml data/20-services.yml --branch fw-cicd-demo`
Expected: objects created (or "already exists" on re-run — idempotent for the demo).

- [ ] **Step 7: Commit**

```bash
git add data/00-zones.yml data/10-addresses.yml data/20-services.yml
git commit -m "feat(data): example zones, addresses, services"
```

---

## Task 6: Author and load the policy, rules, and firewall

**Files:**
- Create: `data/30-policy.yml`, `data/40-rules.yml`, `data/50-firewall.yml`

- [ ] **Step 1: Write `data/30-policy.yml`**

```yaml
---
apiVersion: infrahub.app/v1
kind: Object
spec:
  kind: SecurityPolicy
  data:
    - name: edge-policy
      description: "Edge firewall policy (DMZ + inside)"
```

- [ ] **Step 2: Write `data/40-rules.yml` (one permit, one deny)**

References resolve by human-friendly id (`name__value`) for zones/addresses/services and the policy.

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
        - web-server-01
      destination_services:
        - https
    - name: deny-outside-to-inside
      index: 20
      action: deny
      log: true
      policy: edge-policy
      source_zone: outside
      destination_zone: inside
```

- [ ] **Step 3: Write `data/50-firewall.yml`**

> `SecurityFirewall` inherits Dcim device generics, so it requires the same mandatory
> attributes/relationships as a `DcimPhysicalDevice` (e.g. name, status, role, device_type,
> location, platform). Confirm the required set with `infrahubctl object validate` and fill
> in values that already exist on the instance (or create minimal supporting Dcim objects in
> a `data/45-device-deps.yml` if the instance has none).

```yaml
---
apiVersion: infrahub.app/v1
kind: Object
spec:
  kind: SecurityFirewall
  data:
    - name: ftd-edge-01
      role: edge_firewall
      policy: edge-policy
```

- [ ] **Step 4: Validate all three files**

Run: `uv run infrahubctl object validate data/30-policy.yml data/40-rules.yml data/50-firewall.yml --branch fw-cicd-demo`
Expected: all valid. Resolve any missing-required-field errors for `SecurityFirewall` per the Step 3 note.

- [ ] **Step 5: Load in dependency order**

Run: `uv run infrahubctl object load data/30-policy.yml data/40-rules.yml data/50-firewall.yml --branch fw-cicd-demo`
Expected: policy, then rules (referencing zones/addresses/services/policy), then firewall — all created.

- [ ] **Step 6: Commit**

```bash
git add data/30-policy.yml data/40-rules.yml data/50-firewall.yml
git commit -m "feat(data): example policy, rules, and firewall device"
```

---

## Task 7: Add convenience Makefile and verify end-to-end

**Files:**
- Create: `verify.py`, `Makefile`

- [ ] **Step 1: Write `verify.py`** (the SDK is the reliable way to query — there is no
  `infrahubctl graphql --query`). It reads the same config as `infrahubctl` via `INFRAHUBCTL_CONFIG`,
  so no token is handled separately.

```python
"""Print counts of the Security objects loaded on the demo branch."""
import os
import toml
from infrahub_sdk import InfrahubClientSync, Config

cfg = toml.load(os.environ["INFRAHUBCTL_CONFIG"])
client = InfrahubClientSync(config=Config(address=cfg["server_address"], api_token=cfg["api_token"]))
branch = os.environ.get("INFRAHUB_BRANCH", "fw-cicd-demo")

for kind in [
    "SecurityZone", "SecurityIPAddress", "SecurityService",
    "SecurityPolicy", "SecurityPolicyRule", "SecurityFirewall",
]:
    print(f"{kind}: {len(client.all(kind, branch=branch))}")
```

> If the installed SDK (v1.21.0) uses a different `InfrahubClientSync`/`Config` signature, adjust
> until `uv run python verify.py` runs cleanly and prints the counts — then keep the working form.

- [ ] **Step 2: Write `Makefile`**

```make
BRANCH ?= fw-cicd-demo

.PHONY: load-schema load-data verify

load-schema:
	uv run infrahubctl schema load schemas/security.yml --branch $(BRANCH) --wait 30

load-data:
	uv run infrahubctl object load data/00-zones.yml data/10-addresses.yml data/20-services.yml \
		data/30-policy.yml data/40-rules.yml data/50-firewall.yml --branch $(BRANCH)

verify:
	INFRAHUB_BRANCH=$(BRANCH) uv run python verify.py
```

> The Makefile assumes `INFRAHUBCTL_CONFIG` is exported (Task 2, Step 1).

- [ ] **Step 3: Run the verification target**

Run: `make verify`
Expected: `SecurityPolicy: 1`, `SecurityPolicyRule: 2` (or more), and non-zero zones/addresses/services.

- [ ] **Step 4: Reproducibility check (fresh-eyes dry run)**

Re-read Tasks 4–6 and confirm `make load-schema && make load-data && make verify` reproduces the full state from a clean instance branch. Note any manual step not captured by the Makefile and add it.

- [ ] **Step 5: Commit**

```bash
git add verify.py Makefile
git commit -m "chore: add verify.py + Makefile for schema/data load + verify"
```

---

## Task 8: Write the Part 1 blog post

**Files:**
- Create: `blog/part-1-source-of-truth.md`

- [ ] **Step 1: Write the post**

Structure (use the actual commands/outputs captured while doing Tasks 1–7 — no invented output):
1. **Why a data model, not templates** — policy as queryable objects with relationships, branchable/reviewable.
2. **Tour of the security schema** — `SecurityPolicy` → `SecurityPolicyRule` (zones, addresses, services, action/log) → `SecurityRenderedPolicyRule`; `SecurityFirewall` inheriting Dcim generics. Reference `schemas/security.yml`.
3. **Setup** — repo, `uv sync`, env-var credentials (call out: secrets via env, never committed; `infrahubctl.toml` is git-ignored).
4. **Load the schema** — `make load-schema`, base-schema dependency note.
5. **Model the policy** — walk the `data/*.yml` files; load with `make load-data`; show the objects in the UI + `make verify`.
6. **Recap + what's next** — Part 2 turns this model into a Terraform data source.

- [ ] **Step 2: Self-check the post**

Verify every command in the post was actually run in Tasks 1–7 and every output shown is real. Confirm no secret/token appears in any code block.

- [ ] **Step 3: Commit**

```bash
git add blog/part-1-source-of-truth.md
git commit -m "docs(blog): part 1 — the source of truth"
```

---

## Roadmap — Parts 2–5 (each gets its own just-in-time plan)

### Validation spikes (resolve before the dependent part)

- **V1 — GitLab as a Terraform *provider* registry (gates Part 2).**
  Spike: attempt to publish the generated provider to the self-hosted GitLab and `terraform init` it.
  Acceptance: `terraform init` resolves `infrahub` from GitLab, OR a documented fallback (generic
  package registry + provider-registry index) works. Output: a short `docs/specs/v1-gitlab-registry.md`
  recording the working path and the exact endpoint/`GNUmakefile` changes.

- **V2 — rule-rendering source (gates Part 2/3).**
  Spike: decide between an Infrahub generator populating `SecurityRenderedPolicyRule` vs. querying
  `SecurityPolicyRule` directly. Acceptance: one GraphQL query returns the fields needed to build an
  FMC access rule (zones, networks, ports, action, log) for `edge-policy`. Output: the chosen `.gql`
  query saved in `gql/`.

### Part 2 — Build your own Infrahub Terraform provider
- **Goal:** Generate the provider from the V2 GQL query and publish it to self-hosted GitLab.
- **Key tasks:** copy `gql/*.gql` into the provider repo; `export INFRAHUB_SERVER`; `make all`;
  inspect generated `internal/provider` + `docs/`; retarget GoReleaser env (`TERRAFORM_REGISTRY_ENDPOINT`,
  `RELEASE_URL`, GitLab token, `GPG_FINGERPRINT`) per V1; tag + `make generate_deploy`.
- **Acceptance:** `terraform init` in `terraform/` pulls `infrahub` from GitLab; `data "infrahub_..."`
  returns `edge-policy`'s rules. Blog: `blog/part-2-build-the-provider.md`.

### Part 3 — Dual-provider Terraform, run locally
- **Goal:** Read policy from Infrahub (data source) and create ACP rules on the DevNet/dCloud FMC
  (resource via `CiscoDevNet/fmc`).
- **Key tasks:** reserve the DevNet/dCloud FMC sandbox (document steps); `providers.tf` with both
  providers; map Infrahub fields → FMC access-rule attributes (+ any prerequisite FMC network/port
  objects); `terraform plan`/`apply`; verify in the FMC UI. Cover gotchas: FMC domain UUID, auth,
  rule ordering, idempotency.
- **Acceptance:** `edge-policy`'s permit/deny rules appear in the FMC Access Control Policy.
  Blog: `blog/part-3-dual-provider-local.md`.

### Part 4 — The pipeline
- **Goal:** GitLab CI runs `init/plan/apply`; state in GitLab; plan posted on the MR; triggered by an
  Infrahub webhook on merge.
- **Key tasks:** `.gitlab-ci.yml` (init pulls infrahub from GitLab + fmc from public registry; plan as
  artifact + MR note; apply gated on protected branch/manual); GitLab HTTP backend for TF state; secrets
  as masked + protected CI variables (`INFRAHUB_API_TOKEN`, FMC creds); Infrahub webhook → pipeline
  trigger token.
- **Acceptance:** merging an MR triggers a green pipeline that applies to FMC.
  Blog: `blog/part-4-the-pipeline.md`.

### Part 5 — Firewall rules as code (the payoff)
- **Goal:** Film/document the full day-2 loop.
- **Key tasks:** Infrahub branch → edit a rule → proposed change → review → merge → webhook → pipeline →
  rule on Firepower; capture screenshots/recording cues; recap; "what's next" (other vendors, drift
  detection, rollback).
- **Acceptance:** a single rule edit in Infrahub provably lands on Firepower through the pipeline.
  Blog: `blog/part-5-rules-as-code.md`.
