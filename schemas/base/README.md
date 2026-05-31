# Base schemas (vendored)

These are pinned copies of the OpsMill **infrahub schema-library** base schemas
(`base/location.yml`, `base/ipam.yml`, `base/dcim.yml`), vendored so this repo is
self-contained. The security schema (`schemas/security.yml`) inherits from kinds defined
here, so load these first (order: location, ipam, then dcim). Re-sync from the upstream
schema-library if you need newer base kinds.
