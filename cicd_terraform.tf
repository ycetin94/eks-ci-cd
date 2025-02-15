provider "aws" {
  region = "us-east-1"
}

# Create a VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  name    = "eks-vpc"
  cidr    = "10.0.0.0/16"
  azs     = ["us-east-1a", "us-east-1b", "us-east-1c"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
  enable_nat_gateway = true
}

# Create an EKS Cluster with Spot Instances
module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = "ci-cd-cluster"
  cluster_version = "1.27"
  subnet_ids      = module.vpc.public_subnets
  vpc_id          = module.vpc.vpc_id

  eks_managed_node_groups = {
    spot_nodes = {
      desired_size = 3
      min_size     = 3
      max_size     = 7
      instance_types = ["t3.medium"]
      capacity_type = "SPOT"
    }
  }
}

# Security Groups
module "security" {
  source = "terraform-aws-modules/security-group/aws"
  name   = "eks-security-group"
  vpc_id = module.vpc.vpc_id
}

# AWS Secrets Manager for Database Credentials
resource "aws_secretsmanager_secret" "database" {
  name = "eks-db-secret"
}

resource "aws_secretsmanager_secret_version" "database" {
  secret_id     = aws_secretsmanager_secret.database.id
  secret_string = jsonencode({
    username = "admin"
    password = "change_this_password"
  })
}

# RDS PostgreSQL Database
module "database" {
  family              = "postgres14"
  source              = "terraform-aws-modules/rds/aws"
  identifier          = "ci-cd-db"
  engine              = "postgres"
  engine_version      = "14.5"
  instance_class      = "db.t3.medium"
  allocated_storage   = 20
  db_name             = "cicddb"
  username           = "admin"
  password           = aws_secretsmanager_secret_version.database.secret_string
  vpc_security_group_ids = [module.security.security_group_id]
}

# Deploy Jenkins using Helm
resource "helm_release" "jenkins" {
  name       = "jenkins"
  repository = "https://charts.jenkins.io"
  chart      = "jenkins"
  namespace  = "jenkins"
  set {
    name  = "controller.serviceType"
    value = "LoadBalancer"
  }
}

# Deploy ArgoCD using Helm
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = "argocd"
  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }
}

# Deploy Flask + React Application
resource "kubernetes_deployment" "flask_react_app" {
  metadata {
    name      = "flask-react-app"
    namespace = "default"
    labels = {
      app = "flask-react"
    }
  }

  spec {
    replicas = 3
    selector {
      match_labels = {
        app = "flask-react"
      }
    }
    template {
      metadata {
        labels = {
          app = "flask-react"
        }
      }
      spec {
        container {
          name  = "flask-react-container"
          image = "ycetin94/flask-react-app:latest"

          port {
            container_port = 5000
          }

          resources {
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}

# Kubernetes Service for Flask + React Application
resource "kubernetes_service" "flask_react_service" {
  metadata {
    name      = "flask-react-app"
    namespace = "default"
  }

  spec {
    selector = {
      app = "flask-react"
    }

    port {
      protocol    = "TCP"
      port        = 80
      target_port = 5000
    }

    type = "LoadBalancer"
  }
}

# Kubernetes Ingress for HTTPS with Let's Encrypt
resource "kubernetes_ingress" "app_ingress" {
  metadata {
    name      = "app-ingress"
    namespace = "default"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "cert-manager.io/cluster-issuer" = "letsencrypt"
    }
  }

  spec {
    rule {
      host = "ycsuisse.click"
      http {
        path {
          path = "/"
          backend {
            service_name = "flask-react-app"
            service_port = 80
          }
        }
      }
    }
    tls {
      hosts       = ["ycsuisse.click"]
      secret_name = "ycsuisse-tls"
    }
  }
}

# Deploy Prometheus and Grafana
resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = "monitoring"
}

# Outputs
output "jenkins_url" {
  value = "https://${helm_release.jenkins.metadata[0].name}.elb.amazonaws.com"
}

output "argocd_url" {
  value = "https://${helm_release.argocd.metadata[0].name}.elb.amazonaws.com"
}

output "app_url" {
  value = "https://ycsuisse.click"
}

