# GitLab-managed Terraform/OpenTofu state (HTTP backend), introduced in Part 4.
# The CI pipeline supplies the address + CI_JOB_TOKEN auth via -backend-config
# (see gitlab/.gitlab-ci.yml). For LOCAL runs you can either:
#   - validate only:    tofu init -backend=false && tofu validate
#   - use local state:   comment out this block while iterating locally, or
#   - pass your own:     tofu init -backend-config="address=..." -backend-config="username=..." -backend-config="password=<PAT>"
terraform {
  backend "http" {}
}
