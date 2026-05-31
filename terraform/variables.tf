# All secrets come from variables — set them via TF_VAR_* env vars or a
# git-ignored *.tfvars file (see example.tfvars). Never commit real values.

variable "infrahub_server" {
  type        = string
  description = "Infrahub base URL, e.g. https://your-infrahub.example.com"
}

variable "infrahub_api_token" {
  type        = string
  sensitive   = true
  description = "Infrahub API token"
}

variable "infrahub_branch" {
  type        = string
  default     = "main"
  description = "Infrahub branch to read the policy from"
}

variable "policy_name" {
  type        = string
  default     = "edge-policy"
  description = "Name of the SecurityPolicy in Infrahub to render"
}

variable "fmc_url" {
  type        = string
  description = "FMC base URL, e.g. https://fmcrestapisandbox.cisco.com"
}

variable "fmc_username" {
  type        = string
  description = "FMC username"
}

variable "fmc_password" {
  type        = string
  sensitive   = true
  description = "FMC password"
}
