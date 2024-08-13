output "match_labels" {
  description = "The labels unique to this deployment that can be used to select the Pods in this Workflow"
  value       = module.util.match_labels
}

output "labels" {
  description = "The default labels assigned to all resources in this Workflow"
  value       = module.util.labels
}

output "service_account_name" {
  description = "The default service account used for the Pods"
  value       = kubernetes_service_account.sa.metadata[0].name
}

output "workflow_spec" {
  description = "The specification for the Workflow"
  value       = local.workflow_spec
}

output "generate_name" {
  description = "The prefix for generating Workflow names from this spec"
  value       = "${var.name}-"
}

output "volumes" {
  description = "The volume specification to be applied to all pods generated by this Workflow"
  value       = local.common_volumes
}

output "volume_mounts" {
  description = "The volume mounts to be applied to the main container in each Pod generated by this Workflow"
  value       = local.common_volume_mounts
}

output "container_security_context" {
  description = "The security context to be applied to each container in each Pod generated by this Workflow"
  value       = local.security_context
}

output "env" {
  description = "The environment variables to be added to each container in each Pod generated by this Workflow"
  value       = local.common_env
}

output "tolerations" {
  description = "Tolerations added to each Pod by default"
  value       = module.util.tolerations
}

output "affinity" {
  description = "The affinity added to each Pod by default"
  value       = module.util.affinity
}

output "arguments" {
  description = "The arguments to the workflow"
  value       = var.arguments
}

output "container_defaults" {
  description = "Default options for every container spec"
  value       = local.container_defaults
}

output "aws_role_name" {
  description = "The name of the AWS role used by the Workflow's Service Account"
  value       = module.workflow_perms.role_name
}

output "aws_role_arn" {
  description = "The name of the AWS role used by the Workflow's Service Account"
  value       = module.workflow_perms.role_arn
}
