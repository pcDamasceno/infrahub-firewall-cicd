# Part 4 — The Pipeline: GitLab CI from Merge to Firepower

*Network Automation for Security — Firewall Rules as Code, Part 4 of 5.*

[Part 3](./part-3-dual-provider-local.md) ran the dual-provider Terraform on a laptop. Real
"firewall rules as code" means nobody runs `apply` by hand — a merged policy change deploys itself.
This part puts the run in **GitLab CI**: `validate → plan → apply`, with **GitLab-managed state**,
the **plan rendered on the merge request**, and a trigger that fires when a policy change is merged
in Infrahub.

> **What's verified here:** the pipeline YAML parses and the Terraform config passes `tofu fmt
> -check`/`validate`, and the FMC apply itself was proven in Part 3. The live pipeline run + the
> Infrahub→GitLab webhook are reader-verified against *your* GitLab — same split as Part 2.

We use **OpenTofu** (the open-source Terraform fork) — it's what GitLab now recommends and ships
first-class support for, and it speaks the same provider protocols, so our Terralist `infrahub`
provider and `CiscoDevNet/fmc` work unchanged.

---

## The shape

```
MR opened ─► validate + plan ─► plan summary on the MR
   merge ─► (default branch) ─► plan ─► apply ─► Firepower
                       ▲
   Infrahub webhook ───┘  (CI_PIPELINE_SOURCE == "trigger")
```

Three stages, GitLab-managed state, plan-on-MR, auto-apply on `main` and on Infrahub triggers.

## Where the file lives

The config is at `gitlab/.gitlab-ci.yml`, so set **Settings ▸ CI/CD ▸ "CI/CD configuration file"**
to `gitlab/.gitlab-ci.yml` (or move it to the repo root, GitLab's default). Full setup checklist is
in [`gitlab/README.md`](../gitlab/README.md).

## The pipeline

```yaml
stages: [validate, plan, apply]

variables:
  TF_ROOT: ${CI_PROJECT_DIR}/terraform
  TF_STATE_NAME: firewall
  TF_ADDRESS: ${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/terraform/state/${TF_STATE_NAME}

default:
  image:
    name: ghcr.io/opentofu/opentofu:1.9.0
    entrypoint: [""]
  before_script:
    - cd "${TF_ROOT}"
    - tofu init
        -backend-config="address=${TF_ADDRESS}"
        -backend-config="lock_address=${TF_ADDRESS}/lock"
        -backend-config="unlock_address=${TF_ADDRESS}/lock"
        -backend-config="username=gitlab-ci-token"
        -backend-config="password=${CI_JOB_TOKEN}"
        -backend-config="lock_method=POST"
        -backend-config="unlock_method=DELETE"
```

(Full file, including the `validate`/`plan`/`apply` jobs and their `rules`, is in the repo.)

### GitLab-managed state

No S3, no DynamoDB. `terraform/backend.tf` declares an empty HTTP backend:

```hcl
terraform { backend "http" {} }
```

CI fills it in: the address is `…/api/v4/projects/<id>/terraform/state/firewall`, and auth is
`gitlab-ci-token` + `$CI_JOB_TOKEN` — both injected via `-backend-config` in `before_script`.
GitLab stores and locks the state, encrypted at rest. (Locally: `tofu init -backend=false` to just
validate, or pass your own `-backend-config`.)

### Secrets as CI variables — never in the repo

The providers read everything from `TF_VAR_*`, set as **masked + protected** CI/CD variables:
`TF_VAR_infrahub_api_token`, `TF_VAR_fmc_password`, `TF_VAR_fmc_url`, etc. OpenTofu picks these up
automatically. This is the secure counterpart to Part 1's "token in a file" anti-pattern.

### Plan on the merge request

The `plan` job writes a plan file and a JSON view, exposed as a GitLab **Terraform report**:

```yaml
artifacts:
  paths: [${TF_ROOT}/planfile]
  reports:
    terraform: ${TF_ROOT}/plan.json
```

GitLab renders "X to add, Y to change, Z to destroy" right on the MR — so a firewall change gets the
same review surface as application code before it ever touches the device.

---

## Trigger on a merged policy change (Infrahub → GitLab)

The loop closes with two pieces:

1. **GitLab** — create a pipeline **trigger token** (*Settings ▸ CI/CD ▸ Pipeline trigger tokens*).
2. **Infrahub** — add a **webhook** that fires when a branch / proposed change merges, targeting:
   ```
   POST https://gitlab.example.com/api/v4/projects/<PROJECT_ID>/trigger/pipeline?token=<TRIGGER_TOKEN>&ref=main
   ```

That pipeline runs with `CI_PIPELINE_SOURCE == "trigger"`, which the `plan` and `apply` jobs allow —
so merging a policy change in Infrahub deploys it to Firepower with no human in the `apply` loop.

### Gate or no gate

`apply` auto-runs on `main` and on triggers (the demo loop). For a change-controlled environment,
switch its rule to `when: manual` for an approval button — the plan still posts on the MR either way.

---

## Shortcut: the OpenTofu CI/CD component

If your instance can reach the CI catalog, the explicit jobs collapse to an include that handles
managed state, the MR widget, and state encryption:

```yaml
include:
  - component: gitlab.com/components/opentofu/full-pipeline@<version>
    inputs: { opentofu_version: "1.9.0", root_dir: terraform, state_name: firewall }
```

The explicit pipeline in this repo has no external dependency, which is friendlier for self-hosted
or air-gapped GitLab.

---

## Recap & what's next

A merged policy change now flows through GitLab CI — reviewed as a plan on the MR, applied to
Firepower automatically, with state managed and secrets kept in CI variables. The pieces from Parts
1–3 (Infrahub model, Terralist-served provider, dual-provider Terraform) are now a hands-off
pipeline.

In **[Part 5](./part-5-rules-as-code.md)** we run the whole thing on camera: branch in Infrahub,
edit a rule, open a proposed change, review, merge — and watch the webhook fire the pipeline and the
rule appear on Cisco Firepower. Firewall rules as code, end to end.
