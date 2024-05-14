// Live

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.27.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.12.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "3.25.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.10.0"
    }
  }
}

locals {

  name      = "argo"
  namespace = module.namespace.namespace

  controller_match = {
    id = random_id.controller_id.hex
  }

  server_match = {
    id = random_id.server_id.hex
  }

  configmap_name = "argo-controller"
}

module "pull_through" {
  count  = var.pull_through_cache_enabled ? 1 : 0
  source = "../aws_ecr_pull_through_cache_addresses"
}

resource "random_id" "controller_id" {
  byte_length = 8
  prefix      = "argo-controller-"
}

resource "random_id" "server_id" {
  byte_length = 8
  prefix      = "argo-"
}

module "controller_labels" {
  source = "../kube_labels"

  # generate: common_vars_no_extra_tags.snippet.txt
  pf_stack_version = var.pf_stack_version
  pf_stack_commit  = var.pf_stack_commit
  environment      = var.environment
  region           = var.region
  pf_root_module   = var.pf_root_module
  pf_module        = var.pf_module
  is_local         = var.is_local
  # end-generate

  extra_tags = merge(var.extra_tags, local.controller_match)
}

module "server_labels" {
  source = "../kube_labels"

  # generate: common_vars_no_extra_tags.snippet.txt
  pf_stack_version = var.pf_stack_version
  pf_stack_commit  = var.pf_stack_commit
  environment      = var.environment
  region           = var.region
  pf_root_module   = var.pf_root_module
  pf_module        = var.pf_module
  is_local         = var.is_local
  # end-generate

  extra_tags = merge(var.extra_tags, local.server_match)
}

module "controller_constants" {
  source = "../constants"

  matching_labels = local.controller_match

  # generate: common_vars_no_extra_tags.snippet.txt
  pf_stack_version = var.pf_stack_version
  pf_stack_commit  = var.pf_stack_commit
  environment      = var.environment
  region           = var.region
  pf_root_module   = var.pf_root_module
  pf_module        = var.pf_module
  is_local         = var.is_local
  # end-generate

  extra_tags = merge(var.extra_tags, local.controller_match)
}

module "server_constants" {
  source = "../constants"

  matching_labels = local.server_match

  # generate: common_vars_no_extra_tags.snippet.txt
  pf_stack_version = var.pf_stack_version
  pf_stack_commit  = var.pf_stack_commit
  environment      = var.environment
  region           = var.region
  pf_root_module   = var.pf_root_module
  pf_module        = var.pf_module
  is_local         = var.is_local
  # end-generate

  extra_tags = merge(var.extra_tags, local.server_match)
}

/***************************************
* Kubernetes Namespace
***************************************/

module "namespace" {
  source = "../kube_namespace"

  namespace = local.name

  # generate: pass_common_vars.snippet.txt
  pf_stack_version = var.pf_stack_version
  pf_stack_commit  = var.pf_stack_commit
  environment      = var.environment
  region           = var.region
  pf_root_module   = var.pf_root_module
  is_local         = var.is_local
  extra_tags       = var.extra_tags
  # end-generate
}

/***************************************
* Vault IdP Setup
***************************************/

resource "vault_identity_oidc_key" "argo" {
  name               = "argo"
  allowed_client_ids = ["*"]
  rotation_period    = 60 * 60 * 8
  verification_ttl   = 60 * 60 * 24
}

data "vault_identity_group" "rbac_groups" {
  for_each   = toset(["rbac-superusers", "rbac-admins", "rbac-readers"])
  group_name = each.key
}

resource "vault_identity_oidc_assignment" "argo" {
  name      = "argo"
  group_ids = [for group in data.vault_identity_group.rbac_groups : group.id]
}

resource "vault_identity_oidc_client" "argo" {
  name = "argo"
  key  = vault_identity_oidc_key.argo.name
  redirect_uris = [
    "https://${var.argo_domain}/oauth2/callback"
  ]
  assignments = [
    vault_identity_oidc_assignment.argo.name
  ]
  id_token_ttl     = 60 * 60 * 8
  access_token_ttl = 60 * 60 * 8
}

resource "vault_identity_oidc_scope" "groups" {
  name        = "groups"
  template    = "{\"groups\": {{identity.entity.groups.names}}}" // This MUST be this exact string (not JSON-encoded)
  description = "Groups scope"
}

resource "vault_identity_oidc_provider" "argo" {
  name          = "argo"
  https_enabled = true
  issuer_host   = var.vault_domain
  allowed_client_ids = [
    vault_identity_oidc_client.argo.client_id
  ]
  scopes_supported = [
    vault_identity_oidc_scope.groups.name
  ]
}

/***************************************
* Argo Deployment
***************************************/

resource "kubernetes_secret" "sso_info" {
  metadata {
    name      = "argo-server-sso"
    namespace = local.namespace
    labels    = module.server_labels.kube_labels
  }
  data = {
    client-id     = vault_identity_oidc_client.argo.client_id
    client-secret = vault_identity_oidc_client.argo.client_secret
  }
}

resource "helm_release" "argo" {
  namespace       = local.namespace
  name            = "argo"
  repository      = "https://argoproj.github.io/argo-helm"
  chart           = "argo-workflows"
  version         = var.argo_helm_version
  recreate_pods   = false
  cleanup_on_fail = true
  wait            = true
  wait_for_jobs   = true

  values = [
    yamlencode({
      fullnameOverride = "argo"

      workflow = {
        serviceAccount = {
          create = true
        }
        rbac = {
          create = true // Creates a ServiceAccount so that pods can complete workflows successfully (report status back to argo)
        }
      }

      controller = {
        clusterWorkflowTemplates = {
          enabled = false
        }
        configMap = {
          create = true
          name   = local.configmap_name
        }
        deploymentAnnotations = {
          "configmap.reloader.stakater.com/reload" = local.configmap_name
          "secret.reloader.stakater.com/reload"    = kubernetes_secret.sso_info.metadata[0].name
        }
        image = {
          registry = var.pull_through_cache_enabled ? module.pull_through[0].quay_registry : "quay.io"
        }

        logging = {
          format = "json"
          level  = var.log_level
        }
        pdb = {
          enabled        = true
          maxUnavailable = 1
        }
        #persistence = {} // TODO: Look into Postgres config for this
        podAnnotations = {
          "config.alpha.linkerd.io/proxy-enable-native-sidecar" = "true"
        }
        podLabels         = module.controller_labels.kube_labels
        priorityClassName = module.controller_constants.cluster_important_priority_class_name
        replicas          = 2
        resources = {
          requests = {
            memory = "100Mi"
            cpu    = "100m"
          }
          limits = {
            memory = "130Mi"
          }
        }
        tolerations               = module.controller_constants.burstable_node_toleration_helm
        topologySpreadConstraints = module.controller_constants.topology_spread_zone_preferred
      }

      executor = {
        image = {
          registry = var.pull_through_cache_enabled ? module.pull_through[0].quay_registry : "quay.io"
        }
        resources = {
          requests = {
            memory = "100Mi"
            cpu    = "100m"
          }
          limits = {
            memory = "130Mi"
          }
        }
      }

      server = {
        authModes = ["sso"]
        sso = {
          enabled     = true
          issuer      = vault_identity_oidc_provider.argo.issuer
          redirectUrl = "https://${var.argo_domain}/oauth2/callback"
          clientId = {
            name = kubernetes_secret.sso_info.metadata[0].name
            key  = "client-id"
          }
          clientSecret = {
            name = kubernetes_secret.sso_info.metadata[0].name
            key  = "client-secret"
          }
          rbac = {
            enabled = true
          }
          scopes        = ["openid", "groups"]
          sessionExpiry = "8h"
        }
        deploymentAnnotations = {
          "configmap.reloader.stakater.com/reload" = local.configmap_name
          "secret.reloader.stakater.com/reload"    = kubernetes_secret.sso_info.metadata[0].name
        }
        image = {
          registry = var.pull_through_cache_enabled ? module.pull_through[0].quay_registry : "quay.io"
        }
        logging = {
          format = "json"
          level  = var.log_level
        }

        podAnnotations = {
          "config.alpha.linkerd.io/proxy-enable-native-sidecar" = "true"
        }
        podLabels = module.server_labels.kube_labels

        replicas                  = 2
        priorityClassName         = module.server_constants.cluster_important_priority_class_name
        tolerations               = module.server_constants.burstable_node_toleration_helm
        topologySpreadConstraints = module.server_constants.topology_spread_zone_preferred
        pdb = {
          enabled        = true
          maxUnavailable = 1
        }

        resources = {
          requests = {
            memory = "100Mi"
            cpu    = "100m"
          }
          limits = {
            memory = "130Mi"
          }
        }

      }
    })
  ]
  depends_on = [kubernetes_secret.sso_info]
}

/***************************************
* Argo RBAC
***************************************/

resource "time_rotating" "token_rotation" {
  rotation_days = 7
}

resource "kubernetes_service_account" "superuser" {
  metadata {
    name      = "argo-superuser"
    namespace = local.namespace
    annotations = {
      "workflows.argoproj.io/rbac-rule"                  = "'rbac-superusers' in groups"
      "workflows.argoproj.io/rbac-rule-precedence"       = "0"
      "workflows.argoproj.io/service-account-token.name" = kubernetes_secret.superuser_token.metadata[0].name
    }
  }
}

resource "kubernetes_cluster_role_binding" "superuser_binding" {
  metadata {
    name = "argo-superuser"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.superuser.metadata[0].name
    namespace = local.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "argo-admin" // This is a built in role in the chart
  }
}

resource "kubernetes_secret" "superuser_token" {
  metadata {
    name      = "argo-superuser-${md5(time_rotating.token_rotation.id)}"
    namespace = local.namespace
  }
  type = "kubernetes.io/service-account-token"
}

resource "kubernetes_service_account" "admin" {
  metadata {
    name      = "argo-admin"
    namespace = local.namespace
    annotations = {
      "workflows.argoproj.io/rbac-rule"                  = "'rbac-admins' in groups"
      "workflows.argoproj.io/rbac-rule-precedence"       = "1"
      "workflows.argoproj.io/service-account-token.name" = kubernetes_secret.admin_token.metadata[0].name
    }
  }
}

resource "kubernetes_cluster_role_binding" "admin_binding" {
  metadata {
    name = "argo-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.admin.metadata[0].name
    namespace = local.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "argo-edit" // This is a built in role in the chart
  }
}

resource "kubernetes_secret" "admin_token" {
  metadata {
    name      = "argo-admin-${md5(time_rotating.token_rotation.id)}"
    namespace = local.namespace
  }
  type = "kubernetes.io/service-account-token"
}

resource "kubernetes_service_account" "reader" {
  metadata {
    name      = "argo-reader"
    namespace = local.namespace
    annotations = {
      "workflows.argoproj.io/rbac-rule"                  = "'rbac-readers' in groups"
      "workflows.argoproj.io/rbac-rule-precedence"       = "2"
      "workflows.argoproj.io/service-account-token.name" = kubernetes_secret.reader_token.metadata[0].name
    }
  }
}

resource "kubernetes_cluster_role_binding" "reader_binding" {
  metadata {
    name = "argo-reader"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.reader.metadata[0].name
    namespace = local.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "argo-view" // This is a built in role in the chart
  }
}

resource "kubernetes_secret" "reader_token" {
  metadata {
    name      = "argo-reader-${md5(time_rotating.token_rotation.id)}"
    namespace = local.namespace
  }
  type = "kubernetes.io/service-account-token"
}

/***************************************
* Autoscaling
***************************************/

resource "kubernetes_manifest" "vpa_controller" {
  count = var.vpa_enabled ? 1 : 0
  manifest = {
    apiVersion = "autoscaling.k8s.io/v1"
    kind       = "VerticalPodAutoscaler"
    metadata = {
      name      = "argo-controller"
      namespace = local.namespace
      labels    = module.controller_labels.kube_labels
    }
    spec = {
      targetRef = {
        apiVersion = "apps/v1"
        kind       = "Deployment"
        name       = "argo-workflow-controller"
      }
    }
  }
  depends_on = [helm_release.argo]
}

resource "kubernetes_manifest" "vpa_server" {
  count = var.vpa_enabled ? 1 : 0
  manifest = {
    apiVersion = "autoscaling.k8s.io/v1"
    kind       = "VerticalPodAutoscaler"
    metadata = {
      name      = "argo-server"
      namespace = local.namespace
      labels    = module.server_labels.kube_labels
    }
    spec = {
      targetRef = {
        apiVersion = "apps/v1"
        kind       = "Deployment"
        name       = "argo-server"
      }
    }
  }
  depends_on = [helm_release.argo]
}

/***************************************
* Argo Ingress
***************************************/

module "ingress" {
  count  = var.ingress_enabled ? 1 : 0
  source = "../kube_ingress"

  namespace = local.namespace
  name      = "argo-server"
  ingress_configs = [{
    domains      = [var.argo_domain]
    service      = "argo-server"
    service_port = 2746
  }]

  rate_limiting_enabled          = true
  cross_origin_isolation_enabled = true
  permissions_policy_enabled     = true
  csp_enabled                    = true

  # generate: pass_common_vars.snippet.txt
  pf_stack_version = var.pf_stack_version
  pf_stack_commit  = var.pf_stack_commit
  environment      = var.environment
  region           = var.region
  pf_root_module   = var.pf_root_module
  is_local         = var.is_local
  extra_tags       = var.extra_tags
  # end-generate

  depends_on = [helm_release.argo]
}

