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
   Terraform run:
     • infrahub provider (DATA SOURCE) ← reads intended policy   [served from GitLab registry]
     • CiscoDevNet/fmc   (RESOURCE)    → writes ACP rules to FMC  [public registry]
     • state in GitLab; plan posted to the MR
        ▼
   Cisco Firepower (DevNet/dCloud sandbox FMC)
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

1. **The source of truth** — load the security schema into Infrahub, model an example policy.
2. **Build your own Infrahub Terraform provider** — generate from GQL, publish to GitLab.
3. **Dual-provider Terraform, run locally** — read from Infrahub, write to FMC.
4. **The pipeline** — GitLab CI + Infrahub webhook + state + plan-on-MR.
5. **Firewall rules as code** — the full day-2 demo.

See [`docs/specs/2026-05-31-design.md`](docs/specs/2026-05-31-design.md) for the full design.

> **Secrets:** never commit credentials. Infrahub/FMC tokens belong in GitLab masked + protected
> CI variables, not in tracked files. See `.gitignore`.
