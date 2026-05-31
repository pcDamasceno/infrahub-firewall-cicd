# Network Automation for Security — Firewall Rules as Code

A 5-part blog + video series showing how to manage **Cisco Firepower** firewall rules as code,
with **Infrahub** as the source of truth, a custom **Terraform** provider, and **GitLab CI**.

```
Engineer edits policy ─► Infrahub (security schema = source of truth)
        │  branch + proposed change + merge
        ▼
   Infrahub webhook ─► GitLab CI pipeline
        │
        ▼
   OpenTofu run:
     • infrahub provider (DATA SOURCE) ← reads intended policy   [served via Terralist, GitLab-backed]
     • CiscoDevNet/fmc   (RESOURCE)    → writes ACP rules to FMC  [public registry]
     • state managed by GitLab; plan posted to the MR
        ▼
   Cisco Firepower (FMC)
```

## Repo layout

| Path | Purpose |
|------|---------|
| `terraform/` | Root module: Infrahub data sources + FMC resources |
| `gql/` | GraphQL queries compiled into the custom Infrahub provider |
| `data/` | Example security policy as `infrahubctl` object files |
| `.gitlab-ci.yml` | Pipeline: init / plan / apply (added in Part 4) |
| `blog/` | The 5 posts (markdown) + diagrams |
| `docs/specs/` | Design spec |

## Series

1. [The source of truth](blog/part-1-source-of-truth.md) — load the security schema into Infrahub, model an example policy.
2. [Build your own Infrahub Terraform provider](blog/part-2-build-the-provider.md) — generate from GQL, publish via Terralist (GitLab-backed).
3. [Dual-provider Terraform, run locally](blog/part-3-dual-provider-local.md) — read from Infrahub, write to Cisco FMC.
4. [The pipeline](blog/part-4-the-pipeline.md) — GitLab CI + Infrahub webhook + state + plan-on-MR.
5. [Firewall rules as code](blog/part-5-rules-as-code.md) — the full day-2 demo.

See [`docs/specs/2026-05-31-design.md`](docs/specs/2026-05-31-design.md) for the full design.

> **Secrets:** never commit credentials. Infrahub/FMC tokens belong in GitLab masked + protected
> CI variables, not in tracked files. See `.gitignore`.
