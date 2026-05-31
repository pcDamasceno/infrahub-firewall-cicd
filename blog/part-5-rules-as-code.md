# Part 5 — Firewall Rules as Code: The Day-2 Demo

*Network Automation for Security — Firewall Rules as Code, Part 5 of 5.*

Everything is in place. [Part 1](./part-1-source-of-truth.md) made Infrahub the source of truth,
[Part 2](./part-2-build-the-provider.md) built and published the Infrahub Terraform provider via
Terralist, [Part 3](./part-3-dual-provider-local.md) wired Infrahub → Cisco Firepower, and
[Part 4](./part-4-the-pipeline.md) put it in GitLab CI. This part is the payoff: **change one rule
in Infrahub and watch it land on the firewall — reviewed, versioned, and deployed by pipeline.**

This doubles as the recording script for the video. Shot cues are in *italics*.

---

## The whole picture

```
Engineer edits policy ─► Infrahub (security schema = source of truth)
        │  branch + proposed change + merge
        ▼
   Infrahub webhook ─► GitLab CI pipeline
        │   validate → plan (on the MR) → apply
        ▼
   OpenTofu:  infrahub provider (read)  +  CiscoDevNet/fmc (write)
        ▼
   Cisco Firepower (FMC) — Access Control Policy updated
```

## Pre-flight checklist (have this running before recording)

- **Infrahub**: security schema loaded, `edge-policy` modelled (Part 1), `firewall_policy_rules`
  query in place.
- **Terralist**: the `infrahub` provider published; `terraform init` resolves it (Part 2).
- **FMC**: reachable; the `infrahub-edge-policy` access policy exists from a first `apply` (Part 3).
- **GitLab**: pipeline configured, `TF_VAR_*` set as masked+protected CI variables, a pipeline
  **trigger token** created, and an **Infrahub webhook** pointing at the trigger URL (Part 4).

---

## The walkthrough

### 1. Show the starting state
*Split screen: Infrahub `edge-policy` (2 rules) on the left, the FMC Access Control Policy
`infrahub-edge-policy` on the right.* Point out they match: `allow-inside-to-dmz-https` and
`deny-outside-to-inside`. "This is the source of truth on the left, the firewall on the right — and
a pipeline keeps them in sync."

### 2. Make a change in a branch
*In Infrahub:* create a branch `add-ssh-rule`. Add a new `SecurityPolicyRule` to `edge-policy`:

```yaml
- name: allow-inside-to-dmz-ssh
  index: 15
  action: permit
  log: true
  policy: edge-policy
  source_zone: inside
  destination_zone: dmz
  destination_address:
    - kind: SecurityIPAddress
      data: { name: web-server-01, address: 10.10.20.10/32 }
  destination_services:
    - kind: SecurityService
      data: { name: ssh, port: 22 }
```

*(Remember the Part 1 gotcha: abstract-peer relationships use the explicit `kind`+`data` form.)*

### 3. Open a proposed change and review
*In Infrahub:* open a **Proposed Change** from `add-ssh-rule` → `main`. *Show the data diff* — the
new SSH rule highlighted. "This is the security review surface: a colleague approves the intent, not
raw firewall CLI."

### 4. Merge — and watch the pipeline
*Merge the proposed change.* The Infrahub **webhook** fires the GitLab **trigger**. *Switch to
GitLab CI:* the pipeline runs `validate → plan → apply`. *Open the plan* — "1 to add" (the new
access rule). *Let `apply` complete* (auto on trigger).

### 5. Confirm on Firepower
*Switch to FMC:* refresh `infrahub-edge-policy`. The third rule, `allow-inside-to-dmz-ssh`
(ALLOW, inside→dmz, `10.10.20.10/32`, tcp/22, logging), is now there. "No one logged into the
firewall. The change was a reviewed merge in the source of truth, and the pipeline did the rest."

*(On a real FMC, the final step is a deploy to the managed device — add `fmc_ftd_deploy` to the
pipeline. The shared DevNet sandbox stages rules in the policy without a device deploy.)*

---

## Why this matters

- **One source of truth.** The policy is queryable, related data — not scattered CLI or
  click-ops. Addresses, services, zones, and rules are modelled objects.
- **Security review as code.** Every firewall change is a reviewable diff with an approval gate,
  and the GitLab MR shows the exact plan before anything touches the device.
- **Audit & versioning for free.** Who changed which rule, when, and why — in Git history and
  Infrahub's branch/proposed-change trail.
- **Separation of intent and rendering.** Engineers express intent ("inside may reach the DMZ web
  server on 443/22"); the pipeline renders it into vendor config.

## What's next (beyond this series)

- **More vendors.** Add another provider (Palo Alto, FMC vs FDM, cloud SGs) behind the same Infrahub
  model — the data source is vendor-neutral; only the write side changes.
- **Group/policy expansion.** Use an Infrahub generator to expand address/service *groups* and
  populate `SecurityRenderedPolicyRule`, then drive Terraform off the rendered rules.
- **Drift detection.** Schedule `tofu plan` to flag out-of-band firewall changes against the source
  of truth.
- **Rollback.** Revert the merge in Infrahub → the pipeline reconciles the firewall back.

---

## The series

1. [The source of truth](./part-1-source-of-truth.md) — Infrahub + the security schema.
2. [Build your own Infrahub Terraform provider](./part-2-build-the-provider.md) — generate + publish via Terralist.
3. [Dual-provider Terraform](./part-3-dual-provider-local.md) — Infrahub → Cisco Firepower.
4. [The pipeline](./part-4-the-pipeline.md) — GitLab CI, state, plan-on-MR, webhook.
5. **Firewall rules as code** — the day-2 demo *(this post)*.

Firewall rules, managed like software: modelled, reviewed, versioned, and deployed by pipeline.
That's network automation for security.
