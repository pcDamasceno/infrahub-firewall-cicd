# GitLab CI setup — firewall rules as code

The pipeline (`gitlab/.gitlab-ci.yml`) runs the dual-provider Terraform/OpenTofu config in
[`../terraform`](../terraform): **validate → plan → apply**, with GitLab-managed state and the plan
rendered on the merge request. It deploys when a policy change is merged (or when Infrahub fires a
webhook).

## 1. Point GitLab at this config file

This file lives under `gitlab/`, so set the CI config path:
**Project ▸ Settings ▸ CI/CD ▸ General pipelines ▸ "CI/CD configuration file"** = `gitlab/.gitlab-ci.yml`.
(Or just move the file to the repo root, GitLab's default location.)

## 2. Add CI/CD variables (masked + protected)

**Project ▸ Settings ▸ CI/CD ▸ Variables.** Mark secrets *Masked* and *Protected*:

| Variable | Example | Notes |
|---|---|---|
| `TF_VAR_infrahub_server` | `https://your-infrahub.example.com` | |
| `TF_VAR_infrahub_api_token` | `••••` | masked + protected |
| `TF_VAR_infrahub_branch` | `main` | |
| `TF_VAR_policy_name` | `edge-policy` | |
| `TF_VAR_fmc_url` | `https://fmc.example.com` | |
| `TF_VAR_fmc_username` | `svc-terraform` | |
| `TF_VAR_fmc_password` | `••••` | masked + protected |

OpenTofu reads `TF_VAR_*` automatically. Nothing secret is committed.

## 3. State & registry

- **State** is GitLab-managed (HTTP backend). The pipeline injects the address +
  `gitlab-ci-token`/`$CI_JOB_TOKEN` via `-backend-config` — no manual setup.
- The runner must reach your **Terralist** registry (the `infrahub` provider, Part 2) and the public
  registry (`CiscoDevNet/fmc`). If Terralist uses a private CA, add it to the runner image.

## 4. Trigger on a policy change (Infrahub webhook → pipeline)

1. **GitLab:** create a pipeline trigger token — *Settings ▸ CI/CD ▸ Pipeline trigger tokens*.
2. **Infrahub:** add a **webhook** that fires when a branch / proposed change is merged, targeting:
   ```
   POST https://gitlab.example.com/api/v4/projects/<PROJECT_ID>/trigger/pipeline?token=<TRIGGER_TOKEN>&ref=main
   ```
   The triggered pipeline runs with `CI_PIPELINE_SOURCE == "trigger"`, which the `plan` and `apply`
   jobs allow — so a merged policy change flows straight to Firepower.

> Keep `apply` automatic on `main`/trigger for the demo loop, or switch its rule to `when: manual`
> for an approval gate (see the comment in `.gitlab-ci.yml`).

## Shortcut: the OpenTofu CI/CD component

Instead of the explicit jobs, you can include the OpenTofu component (handles managed state, the MR
plan widget, and state encryption):

```yaml
include:
  - component: gitlab.com/components/opentofu/full-pipeline@<version>
    inputs:
      version: "<component-version>"
      opentofu_version: "1.9.0"
      root_dir: terraform
      state_name: firewall
```

Requires the runner/instance to reach the component (gitlab.com or a mirrored CI catalog). The
explicit pipeline here has no such dependency.
