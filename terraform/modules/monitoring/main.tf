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

variable "namespace" {
  description = "Existing namespace to install into (owned by the argocd module, which also provisions the exporter's github-token secret there); taking it as an input makes the creation ordering an implicit dependency"
  type        = string
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

# Slim lab profile of kube-prometheus-stack: no Alertmanager (nothing pages
# a lab), 12h retention on emptyDir (metrics are disposable; the SLO story
# is the dashboard, not long-term storage), single replicas, small
# requests sized against 2x t3.small worth of headroom.
resource "helm_release" "kube_prometheus_stack" {
  name             = "kps"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "87.9.0"
  namespace        = var.namespace
  create_namespace = false
  timeout          = 900

  values = [yamlencode({
    alertmanager = { enabled = false }

    prometheus = {
      prometheusSpec = {
        retention = "12h"
        replicas  = 1
        resources = {
          requests = { cpu = "100m", memory = "350Mi" }
          limits   = { memory = "700Mi" }
        }
        # Discover every ServiceMonitor/PodMonitor in the cluster, not just
        # ones labeled with this Helm release - so karpenter/spot-exporter
        # monitors in plain YAML files are picked up.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
      }
    }

    grafana = {
      enabled       = true
      adminPassword = "prlab-grafana" # lab only; UI reachable via port-forward, never an ALB
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }
      sidecar = {
        dashboards = {
          enabled = true
          label   = "grafana_dashboard"
        }
      }
    }

    kube-state-metrics = {
      resources = {
        requests = { cpu = "25m", memory = "48Mi" }
        limits   = { memory = "128Mi" }
      }
    }

    prometheus-node-exporter = {
      resources = {
        requests = { cpu = "25m", memory = "24Mi" }
        limits   = { memory = "64Mi" }
      }
    }

    prometheusOperator = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { memory = "192Mi" }
      }
    }

    # Half the bundled rules/dashboards target components EKS hides
    # (etcd, scheduler, controller-manager, kube-proxy metrics) - disable
    # to avoid permanently-red panels and wasted scrapes.
    kubeEtcd              = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeProxy             = { enabled = false }
  })]
}
