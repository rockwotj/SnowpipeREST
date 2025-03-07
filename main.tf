terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.24"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "google" {
  project = var.project
  region  = "us-central1-c"
}

variable "project" {
  description = "GCP Project ID"
  type        = string
  default     = "rp-byoc-tyler"
}

variable "zone" {
  description = "GCP Zone"
  type        = string
  default     = "us-central1-c"
}

# Create a GKE cluster (without a default node pool)
resource "google_container_cluster" "primary" {
  name                     = "rockwood-snowflake-testing-cluster"
  location                 = var.zone
  initial_node_count       = 1
  remove_default_node_pool = true
  network                  = "default"
  subnetwork               = "default"
  deletion_protection = false
  maintenance_policy {
    recurring_window {
      end_time   = "2025-03-07T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
      start_time = "2025-03-06T06:00:00Z"
    }
  }
}

# Node Pool for the Load Generator
resource "google_container_node_pool" "loadgen_nodes" {
  name               = "loadgen-nodes"
  cluster            = google_container_cluster.primary.id
  location           = var.zone
  initial_node_count = 2

  node_config {
    machine_type = "c4-standard-4"
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
    # Label nodes in this pool with "role=loadgen"
    labels = {
      role = "loadgen"
    }
  }
}

# Node Pool for the HTTP Service
resource "google_container_node_pool" "http_service_nodes" {
  name               = "http-service-nodes"
  cluster            = google_container_cluster.primary.id
  location           = var.zone
  initial_node_count = 3

  node_config {
    machine_type = "c4-standard-8"
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
    # Label nodes in this pool with "role=http"
    labels = {
      role = "http"
    }
  }
}

# Get current GCP credentials to configure the Kubernetes provider
data "google_client_config" "current" {}

provider "kubernetes" {
  host = "https://${google_container_cluster.primary.endpoint}"

  cluster_ca_certificate = base64decode(
    google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  )

  token = data.google_client_config.current.access_token
}

# Deployment: Load Generator running a simple curl container.
resource "kubernetes_deployment" "load_generator" {
  metadata {
    name = "load-generator"
    labels = {
      app = "load-generator"
    }
  }

  depends_on = [google_container_node_pool.loadgen_nodes]

  timeouts {
    create = "1m"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "load-generator"
      }
    }

    template {
      metadata {
        labels = {
          app = "load-generator"
        }
      }

      spec {
        # Ensure pods are scheduled onto the load generator node pool
        node_selector = {
          role = "loadgen"
        }

        container {
          name  = "load-generator"
          image = "rockwoodredpanda/post_load_gen:v9"
          env {
            name  = "GOMAXPROCS"
            value = "1"
          }
          env {
            name  = "NUM_WORKERS"
            value = "1"
          }
          resources {
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
            requests = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_secret" "redpanda_license" {
  metadata {
    name = "redpanda-license"
  }
  data = {
    REDPANDA_LICENSE = file("${path.module}/redpanda.license")
  }
}

resource "kubernetes_secret" "snowflake_key" {
  metadata {
    name = "snowflake-key"
  }
  data = {
    SNOWFLAKE_KEY = file("${path.module}/rsa_key.p8")
  }
}

resource "kubernetes_config_map" "connect_yaml" {
  metadata {
    name = "connect-yaml"
  }

  data = {
    "connect.yaml" = file("${path.module}/connect.yaml")
  }
}

resource "kubernetes_storage_class" "hyperdisk" {
  metadata {
    name = "hyperdisk"
  }
  storage_provisioner    = "pd.csi.storage.gke.io"
  reclaim_policy         = "Retain"
  allow_volume_expansion = true
  parameters = {
    type                               = "hyperdisk-balanced"
    "provisioned-throughput-on-create" = "250Mi"
    "provisioned-iops-on-create"       = "7000"
  }
  # mount_options = ["file_mode=0700", "dir_mode=0777", "mfsymlinks", "uid=1000", "gid=1000", "nobrl", "cache=none"]
}

# StatefulSet: HTTP Service (Nginx) with persistent storage.
resource "kubernetes_stateful_set" "http_service" {
  metadata {
    name = "http-service"
    labels = {
      app = "http-service"
    }
  }

  depends_on = [google_container_node_pool.http_service_nodes]

  timeouts {
    # create = "1m"
  }

  spec {
    service_name = "http-service" # Ties the StatefulSet to the headless service.
    replicas     = 3

    selector {
      match_labels = {
        app = "http-service"
      }
    }

    template {
      metadata {
        labels = {
          app = "http-service"
        }
      }
      spec {
        # Ensure pods are scheduled onto the HTTP service node pool
        node_selector = {
          role = "http"
        }

        init_container {
          name  = "volume-permissions"
          image = "busybox"
          command = [
            "sh",
            "-c",
            "mkdir -p /data && ls -lah /data && df -h"
          ]
          volume_mount {
            mount_path = "/data"
            name       = "connect-storage"
          }
          security_context {
            run_as_user = 0
          }
        }

        container {
          name  = "http-service"
          image = "rockwoodredpanda/connect:optimized_wal_v1"
          args  = ["run", "--watcher", "/connect.yaml"]

          port {
            container_port = 80
            name           = "http"
          }

          port {
            container_port = 4195
            name           = "benthos"
          }

          volume_mount {
            mount_path = "/data"
            name       = "connect-storage"
          }
          security_context {
            # Run as root for the volume to work
            run_as_user = 0
          }

          volume_mount {
            mount_path = "/connect.yaml"
            sub_path   = "connect.yaml"
            name       = "connect-config"
            read_only  = true
          }

          resources {
            limits = {
              cpu    = "7"
              memory = "25Gi"
            }
            requests = {
              cpu    = "7"
              memory = "25Gi"
            }
          }
          env {
            name  = "GOMAXPROCS"
            value = "7"
          }
          env {
            name  = "GOMEMLIMIT"
            value = "24GiB"
          }
          env {
            name = "REDPANDA_LICENSE"
            value_from {
              secret_key_ref {
                name = "redpanda-license"
                key  = "REDPANDA_LICENSE"
              }
            }
          }
          env {
            name = "SNOWFLAKE_KEY"
            value_from {
              secret_key_ref {
                name = "snowflake-key"
                key  = "SNOWFLAKE_KEY"
              }
            }
          }
          env {
            name = "K8S_POD_ID"
            value_from {
              field_ref {
                field_path = "metadata.labels['apps.kubernetes.io/pod-index']"
              }
            }
          }
        }
        volume {
          name = "connect-config"
          config_map {
            name = "connect-yaml"
            # Set permissions for the mounted files
            default_mode = "0644"
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "connect-storage"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "hyperdisk"
        resources {
          requests = {
            storage = "128Gi"
          }
        }
      }
    }
  }
}

# Headless Service for the StatefulSet to enable stable DNS for pods.
resource "kubernetes_service" "http_service" {
  metadata {
    name = "http-service"
    labels = {
      app = "http-service"
    }
    annotations = {
      "cloud.google.com/load-balancer-type" = "Internal"
    }
  }

  spec {
    type = "ClusterIP"
    selector = {
      app = "http-service"
    }
    port {
      port        = 80
      target_port = 80
    }
  }
}

