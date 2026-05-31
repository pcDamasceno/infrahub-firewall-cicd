terraform {
  required_providers {
    # Custom Infrahub provider, built in Part 2 and served from Terralist.
    # Replace the host/authority with your Terralist registry + authority.
    infrahub = {
      source  = "registry.example.com/netauto/infrahub"
      version = "~> 1.0"
    }
    # Official Cisco FMC provider (public registry). VERIFIED with v2.4.0.
    fmc = {
      source  = "CiscoDevNet/fmc"
      version = "~> 2.4"
    }
  }
}

# Reads intended policy out of Infrahub (source of truth).
provider "infrahub" {
  api_key         = var.infrahub_api_token
  infrahub_server = var.infrahub_server
  branch          = var.infrahub_branch
}

# Writes Access Control rules to Cisco Firepower Management Center.
# NOTE: the DevNet FMC sandbox caps concurrent API tokens — don't hold another
# token (e.g. a stray curl session) while Terraform runs, or the provider's
# auth can return 401 "failed to retrieve FMC version".
provider "fmc" {
  url      = var.fmc_url
  username = var.fmc_username
  password = var.fmc_password
  insecure = true # sandbox uses a self-signed cert
}
