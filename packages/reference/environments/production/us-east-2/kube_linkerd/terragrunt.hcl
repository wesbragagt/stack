include "panfactum" {
  path   = find_in_parent_folders("panfactum.hcl")
  expose = true
}

terraform {
  source = include.panfactum.locals.pf_stack_source
}

dependency "cert_manager" {
  config_path  = "../kube_cert_manager"
  skip_outputs = true
}

dependency "reflector" {
  config_path  = "../kube_reflector"
  skip_outputs = true
}

dependency "cert_issuers" {
  config_path = "../kube_cert_issuers"
}

inputs = {
  vault_ca_crt       = dependency.cert_issuers.outputs.vault_ca_crt
  monitoring_enabled = false
}
