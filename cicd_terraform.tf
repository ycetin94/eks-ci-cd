terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# IAM Role for EKS Cluster
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

# IAM Role for EKS Nodes
resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

# Attach Required Policies to EKS Node Role
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "ecr_readonly_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_role.name
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

# Security Groups
module "security" {
  source = "terraform-aws-modules/security-group/aws"
  name   = "eks-security-group"
  vpc_id = module.vpc.vpc_id
}

# Create an EKS Cluster with Spot Instances
module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = "ci-cd-cluster"
  cluster_version = "1.32"
  subnet_ids      = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id
  iam_role_arn    = aws_iam_role.eks_cluster_role.arn

  eks_managed_node_groups = {
    spot_nodes = {
      desired_size   = 3 
      min_size       = 1
      max_size       = 7
      instance_types = ["t3.medium", "t3.large", "m5.large"]
      capacity_type  = "SPOT"
      iam_role_arn   = aws_iam_role.eks_node_role.arn
    }
  }

  depends_on = [aws_iam_role.eks_node_role, aws_iam_role.eks_cluster_role]
}

data "aws_eks_cluster" "eks" {
  name = module.eks.cluster_name

  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "eks" {
  name = module.eks.cluster_name

  depends_on = [module.eks]
}


provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks.endpoint
  token                  = data.aws_eks_cluster_auth.eks.token
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
    
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.eks.endpoint
    token                  = data.aws_eks_cluster_auth.eks.token
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
  }
}


# AWS Secrets Manager for Database Credentials
data "aws_secretsmanager_secret" "database" {
  name = "eks-db-secret"
}


resource "aws_secretsmanager_secret_version" "database" {
  secret_id     = data.aws_secretsmanager_secret.database.id
  secret_string = jsonencode({
    username = "admin"
    password = "change_this_password"
  })

  
}

# RDS PostgreSQL Database
module "database" {
  source              = "terraform-aws-modules/rds/aws"
  identifier          = "ci-cd-db"
  engine              = "postgres"
  engine_version      = "14.4"
  instance_class      = "db.t3.medium"
  allocated_storage   = 20
  db_name             = "cicddb"
  username           = "admin"
  password           = jsondecode(aws_secretsmanager_secret_version.database.secret_string)["password"]
  vpc_security_group_ids = [module.security.security_group_id]
  family = "postgres14"

  depends_on = [
    module.security,
    aws_secretsmanager_secret_version.database
  ]
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

  depends_on = [module.eks]
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

  depends_on = [module.eks]
}

# ArgoCD Git Repository Configuration
resource "kubectl_manifest" "argocd_git_repo" {
  yaml_body = <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: eks-ci-cd
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "https://github.com/ycetin94/eks-ci-cd"
    targetRevision: main
    path: "helm/app-chart"
  destination:
    server: "https://kubernetes.default.svc"
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
YAML

  depends_on = [helm_release.argocd]
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

  depends_on = [kubernetes_deployment.flask_react_app]
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

  depends_on = [kubernetes_service.flask_react_service]
}

# Deploy Prometheus and Grafana
resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = "monitoring"

  depends_on = [module.eks]
}

# Outputs
output "jenkins_url" {
  value = helm_release.jenkins.metadata[0].name
}

output "argocd_url" {
  value = helm_release.argocd.metadata[0].name
}

output "app_url" {
  value = "https://ycsuisse.click"
}











