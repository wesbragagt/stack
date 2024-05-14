include "panfactum" {
  path   = find_in_parent_folders("panfactum.hcl")
  expose = true
}

terraform {
  source = include.panfactum.locals.pf_stack_source
}

dependency "cluster" {
  config_path = "../aws_eks"
}

dependency "vault" {
  config_path = "../kube_vault"
}

inputs = {
  argo_domain  = "argo.prod.panfactum.com"
  vault_domain = dependency.vault.outputs.vault_domains[0]

  pull_through_cache_enabled = true
  vpa_enabled                = true
}