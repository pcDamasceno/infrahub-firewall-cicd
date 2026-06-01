# Part 2 — Build Your Own Infrahub Terraform Provider (and publish it on GitLab)

*Network Automation for Security — Firewall Rules as Code, Part 2 of 5.*

In [Part 1](./part-1-source-of-truth.md) we made Infrahub the source of truth: we loaded
the security schema and modelled an `edge-policy` with two rules, on a branch called
`fw-cicd-demo`. Now we turn that data into something Terraform can read — a custom
**Infrahub Terraform provider** — and publish it to a private registry that GitLab can back.

> **What's verified in this post vs. what you'll verify:** the GraphQL data-source query
> below was run against a live Infrahub instance and returns exactly the data shown. The
> provider build, the Terralist deployment, and the GitLab publish are written as
> instructions for *your* environment — that's the half you reproduce and verify, since it
> targets your GitLab and your registry host.

---

## The plot twist: GitLab can't host a Terraform *provider*

The obvious plan is "push the provider to GitLab's Terraform registry." It doesn't work, and
the reason is worth understanding because it shapes the whole episode.

Terraform has **two different registry protocols**, advertised through service discovery at
`/.well-known/terraform.json`:

| | Modules | Providers |
|---|---|---|
| Service-discovery key | `modules.v1` | `providers.v1` |
| Artifact | source **tarball** | per-OS/arch compiled **binary** zip |
| Extras | — | `SHA256SUMS` + GPG **signature** + signing **public key** |
| Consumed as | `source = "host/ns/name/system"` | `source = "host/ns/type"` |

**GitLab's Terraform Module Registry implements `modules.v1` only.** When `terraform init`
resolves a *provider* `source`, it queries the host for `providers.v1`, asks
`:namespace/:type/versions`, then downloads `:namespace/:type/:version/download/:os/:arch`
and verifies the GPG-signed checksums. GitLab advertises no `providers.v1` endpoint, and a
module tarball is not a signed per-platform binary — so provider resolution simply fails.
Provider hosting on GitLab is still an open feature request
([gitlab-org/gitlab#356716](https://gitlab.com/gitlab-org/gitlab/-/issues/356716)).

So we keep GitLab in the picture — for source, CI, and as the artifact store — and put a
small registry that *does* speak `providers.v1` in front of it. We'll use
**[Terralist](https://www.terralist.io/)**, an open-source private registry for modules and
providers, with GitLab OAuth and a storage backend (S3/GCS/Azure/local).

```
gql/ query ──► marcom4rtinez generator ──► Go provider (terraform-provider-infrahub)
                                                │  goreleaser: multi-OS zips + SHA256SUMS + .sig
                                                ▼
                                   GitLab (release assets / generic packages)  ◄── artifact store
                                                │  POST /v1/api/providers/.../upload
                                                ▼
                                   Terralist  (speaks providers.v1) ──► terraform init
```

---

## The data source: one query, verified

The provider generator we use — [`marcom4rtinez/infrahub-terraform-provider-generator`](https://github.com/marcom4rtinez/terraform-provider-infrahub)
— turns a **GraphQL query into a Terraform data source** (and mutations into resources). So the
provider's capabilities are defined by the `.gql` files we drop into `gql/`.

Here's the query that pulls a policy's rules with everything an FMC access rule needs
(`gql/firewall_policy_rules.gql` in this repo):

```graphql
query FirewallPolicyRules($policy: String!) {
  SecurityPolicyRule(policy__name__value: $policy) {
    edges { node {
      name { value }  index { value }  action { value }  log { value }
      source_zone { node { name { value } } }
      destination_zone { node { name { value } } }
      destination_address { edges { node {
        __typename
        ... on SecurityIPAddress { name { value } address { value } }
        ... on SecurityPrefix    { name { value } prefix  { value } }
      } } }
      destination_services { edges { node {
        __typename
        ... on SecurityService { name { value } port { value } }
      } } }
      # source_address / source_services follow the same shape
    } }
  }
}
```

Two things to notice:

1. **The abstract-peer inline fragments.** Recall the gotcha from Part 1: `destination_address`
   points at the *abstract* `SecurityGenericAddress`, and `destination_services` at
   `SecurityGenericService`. You can't read `address`/`port` off the abstract type — you ask for
   them on the concrete type with `... on SecurityIPAddress { address { value } }`. Same idea that
   bit us at load time, now on the read side.
2. **The filter is a related-attribute lookup.** `SecurityPolicyRule(policy__name__value: $policy)`
   filters rules by their parent policy's name — so the data source takes a policy name and
   returns just that policy's rules.

Run against the live `fw-cicd-demo` branch, this returns (trimmed):

```json
{ "SecurityPolicyRule": { "edges": [
  { "node": {
      "name": {"value": "allow-inside-to-dmz-https"},
      "index": {"value": 10}, "action": {"value": "permit"}, "log": {"value": true},
      "source_zone": {"node": {"name": {"value": "inside"}}},
      "destination_zone": {"node": {"name": {"value": "dmz"}}},
      "destination_address": {"edges": [{"node": {
        "__typename": "SecurityIPAddress", "name": {"value": "web-server-01"},
        "address": {"value": "10.10.20.10/32"} }}]},
      "destination_services": {"edges": [{"node": {
        "__typename": "SecurityService", "name": {"value": "https"},
        "port": {"value": 443} }}]} } },
  { "node": { "name": {"value": "deny-outside-to-inside"}, "index": {"value": 20},
      "action": {"value": "deny"}, "source_zone": {"node": {"name": {"value": "outside"}}},
      "destination_zone": {"node": {"name": {"value": "inside"}}} } }
] } }
```

That's the contract for Part 3's FMC mapping. Now let's wrap it in a provider.

---

## Generate the provider

The provider is generated from a template repo — start from
[`marcom4rtinez/terraform-provider-infrahub`](https://github.com/marcom4rtinez/terraform-provider-infrahub)
(GitHub "Use this template", or clone it). The name **must** start with `terraform-provider-`.

```bash
git clone <your-fork-of>/terraform-provider-infrahub
cd terraform-provider-infrahub

# 1. Drop the data-source query in
cp ../infrahub-firewall-cicd/gql/firewall_policy_rules.gql gql/

# 2. Point the generator at your Infrahub
export INFRAHUB_SERVER="https://your-infrahub.example.com"

# 3. Generate SDK + provider + docs
make all
```

`make all` runs, in order: the **generator** (`...generator@latest --artifacts`) which reads
`gql/`; **`generate_sdk`** which pulls the GraphQL schema and runs `genqlient`; then
`fmt`/`lint`/`install`/`generate`.

> ### Gotcha: which Infrahub branch does the schema come from?
> `sdk/pull_schema.sh` fetches `"$INFRAHUB_SERVER/schema.graphql?branch=$branch"` where
> `$branch` is the **current git branch name** of the provider repo (falling back to `main`).
> The generated SDK only knows the `Security*` kinds if they exist on that Infrahub branch.
> Two clean options:
> - **Merge `fw-cicd-demo` → `main` in Infrahub first** (you reviewed it in Part 1), then build
>   from the provider repo's `main`; or
> - name the provider repo's git branch to match an Infrahub branch that carries the schema.
>
> If your data sources come out missing the Security types, this is almost always why.

Requirements on your build host: **Go** (1.24+ works), `golangci-lint`, and `gpg`. After
`make all` you'll have a working provider in `internal/provider/` and docs under `docs/`.

---

## Retarget the provider for Terralist + GitLab

The template ships pointed at the author's own registry. Three changes make it yours.

**1. The provider's registry address** (`main.go`). This must match the `source` your users will write. With a Terralist host `registry.example.com` and an authority (org) `netauto`:

```go
opts := providerserver.ServeOpts{
    Address: "registry.example.com/netauto/infrahub",
    Debug:   debug,
}
```

**2. Build + sign + ship artifacts to GitLab** (`.goreleaser.yml`). The template already builds
all OS/arch zips, a `SHA256SUMS`, and GPG-signs it. Point the release at your **self-hosted
GitLab** so the zips/checksums/signature live there:

```yaml
# .goreleaser.yml — add a gitlab_urls block for self-managed GitLab
gitlab_urls:
  api: https://gitlab.example.com/api/v4/
  download: https://gitlab.example.com
  use_package_registry: true   # publish archives to GitLab's generic Package Registry
```

Export the signing + publish env before releasing:

```bash
export GPG_FINGERPRINT=<your-key-id>
export GPG_PUBLIC_KEY=$(gpg --armor --export $GPG_FINGERPRINT)
export GITLAB_TOKEN=<token-with-api-scope>
export RELEASE_URL="https://gitlab.example.com/netauto/terraform-provider-infrahub/-/releases"
```

**3. Replace the registry upload with a Terralist upload.** The template's `upload_registry`
target POSTs to the author's custom registry. Swap it for a Terralist publish (next section).

---

## Deploy Terralist (the `providers.v1` front end)

Run Terralist with Docker and a `config.yaml`. Use **GitLab** as the OAuth provider so logins
ride your existing GitLab identities, and pick a storage backend:

```yaml
# config.yaml
oauth-provider: gitlab
gl-client-id: ${GITLAB_OAUTH_CLIENT_ID}
gl-client-secret: ${GITLAB_OAUTH_CLIENT_SECRET}
token-signing-secret: ${TOKEN_SIGNING_SECRET}
cookie-secret: ${COOKIE_SECRET}

# storage backend (S3 shown; local/GCS/Azure also supported)
storage-resolver: s3
s3-bucket-name: terralist-artifacts

# a master key for CI publishing (or mint scoped API keys in Settings → API Keys)
master-api-key: ${TERRALIST_MASTER_API_KEY}
```

```bash
docker run --rm -it -p 5758:5758 -v ${PWD}:/app \
  ghcr.io/terralist/terralist server --config /app/config.yaml
```

In the Terralist UI, create an **authority** (e.g. `netauto`) and **add your GPG signing
public key** to it — Terraform uses the registry-provided key to validate the downloaded
provider's signature.

---

## Publish the provider

Tag a version and let goreleaser build + sign + push artifacts to GitLab:

```bash
git tag -a v1.0 -m "Infrahub provider with firewall_policy_rules data source"
goreleaser release --clean          # builds zips + SHA256SUMS + .sig, publishes to GitLab
```

Then register the version with Terralist by POSTing a payload that points `download_url`,
`shasums.url`, and `signature_url` at the GitLab-hosted artifacts:

```bash
curl -L -X POST \
  -H "Authorization: Bearer x-api-key:$TERRALIST_MASTER_API_KEY" \
  "https://registry.example.com/v1/api/providers/netauto/infrahub/1.0/upload" \
  -d '{
    "protocols": ["6.0"],
    "shasums": {
      "url":           "https://gitlab.example.com/.../terraform-provider-infrahub_1.0_SHA256SUMS",
      "signature_url": "https://gitlab.example.com/.../terraform-provider-infrahub_1.0_SHA256SUMS.sig"
    },
    "platforms": [
      { "os": "linux",  "arch": "amd64",
        "download_url": "https://gitlab.example.com/.../terraform-provider-infrahub_1.0_linux_amd64.zip",
        "shasum": "<sha256-from-SHA256SUMS>" }
    ]
  }'
```

(Add one `platforms[]` entry per OS/arch you built. The asset URLs are whatever GitLab assigned
in the release / generic package registry — scriptable from the goreleaser `dist/` output or the
GitLab releases API, which is what Part 4 will automate in CI.)

---

## Consume it

Now Terraform can resolve the provider through Terralist's `providers.v1`:

```hcl
# terraform/providers.tf
terraform {
  required_providers {
    infrahub = {
      source  = "registry.example.com/netauto/infrahub"
      version = "1.0"
    }
  }
}

provider "infrahub" {
  api_key         = var.infrahub_api_token          # from a variable / env, never hardcoded
  infrahub_server = "https://your-infrahub.example.com"
  branch          = "main"
}
```

```bash
terraform init     # discovers providers.v1 on registry.example.com, downloads + verifies the signed zip
```

If you'd rather not stand up Terralist while iterating locally, the template also documents a
`~/.terraformrc` **dev override** that points the provider `source` at your local Go bin — handy
for Part 3 development before the registry is in place.

---

## Recap & what's next

- GitLab can't serve a Terraform *provider* (it's `modules.v1` only) — so we front GitLab with
  **Terralist**, which speaks `providers.v1`, and let GitLab be the artifact store + CI + OAuth.
- We generated a provider whose **`firewall_policy_rules` data source** is driven by a verified
  GraphQL query — the same query that returns `edge-policy`'s permit/deny rules with their zones,
  networks, and ports.
- We published it (goreleaser → GitLab artifacts → Terralist) and resolved it with `terraform init`.

In **[Part 3](./part-3-dual-provider-local.md)** we add the official **`CiscoDevNet/fmc`** provider
alongside this one and write the mapping that turns each Infrahub rule into a Cisco Firepower
Access Control rule — a single local `terraform apply`, Infrahub on the read side, FMC on the
write side. Then Part 4 puts the whole thing in a GitLab pipeline.
