terraform {
  required_version = ">= 1.7"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.34"
    }
  }
}

variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "cluster_ca_certificate" {
  type = string
}

variable "region" {
  type = string
}

variable "github_token" {
  description = "GitHub PAT used by the ApplicationSet PR generator (to poll open PRs) and by ArgoCD Notifications (to post PR comments). Never written to state in plaintext beyond what the Kubernetes Secret itself requires."
  type        = string
  sensitive   = true
}

provider "kubernetes" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = var.cluster_endpoint
    cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

# The monitoring namespace lives here (not in the monitoring module)
# because this module already holds the GitHub token safely, and the SLO
# exporter in monitoring needs the same token to read PR created_at
# timestamps. One owner for both namespace and secret keeps the
# token-handling surface in a single module.
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "kubernetes_secret_v1" "monitoring_github_token" {
  metadata {
    name      = "github-token"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  data = {
    github-token = var.github_token
  }
}

output "monitoring_namespace" {
  value = kubernetes_namespace_v1.monitoring.metadata[0].name
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.1.2"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  # ArgoCD's own UI/API is reached via `kubectl port-forward` for this lab -
  # no separate ALB/ingress for it, which would be another idle-cost ELB.
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # Bundled notifications controller posts the "preview ready" PR comment;
  # see argocd/notifications.yaml for the actual trigger/template.
  set {
    name  = "notifications.enabled"
    value = "true"
  }

  # The chart's own notifications sub-template already creates a Secret
  # named "argocd-notifications-secret". A separate Terraform-managed
  # Secret with the same name collides on Helm's ownership check ("exists
  # and cannot be imported into the current release") - the same class of
  # problem as the preview-app chart's namespace conflict in Phase 1.
  # Letting the chart own the Secret via its own values avoids that.
  set {
    name  = "notifications.secret.create"
    value = "true"
  }
  set_sensitive {
    name  = "notifications.secret.items.github-token"
    value = var.github_token
  }

  # The ApplicationSet Pull Request generator (in argocd/applicationset-
  # previews.yaml, applied separately) reads the same key from this same
  # chart-managed Secret to poll prlab-demo-app for open PRs.

  depends_on = [kubernetes_namespace_v1.argocd]
}
