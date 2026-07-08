terraform {
  required_version = ">= 1.7"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
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

resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  version          = "3.7.2" # kyverno v1.17.2
  namespace        = "kyverno"
  create_namespace = true

  # Single replicas and modest resources throughout: this is a 2-node
  # t3.small lab, not an HA control plane. The chart's HA guidance (3
  # admission replicas) trades memory we don't have for availability the
  # lab doesn't need. Cleanup controller is disabled outright - nothing
  # here uses CleanupPolicies (the TTL reaper is deliberately its own
  # auditable Python CronJob, not a Kyverno cleanup rule).
  set {
    name  = "admissionController.replicas"
    value = "1"
  }
  set {
    name  = "admissionController.container.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "admissionController.container.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "admissionController.container.resources.limits.memory"
    value = "384Mi"
  }
  set {
    name  = "backgroundController.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "backgroundController.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "backgroundController.resources.limits.memory"
    value = "256Mi"
  }
  set {
    name  = "reportsController.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "reportsController.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "reportsController.resources.limits.memory"
    value = "256Mi"
  }
  set {
    name  = "cleanupController.enabled"
    value = "false"
  }
}
