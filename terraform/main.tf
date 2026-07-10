# ══════════════════════════════════════════════════════════════════
#  Karpenter ACD demo — base infrastructure (the CORRECT state)
#
#  Every "fix" in the scenarios brings reality back to THIS file.
#  IaC owns the infrastructure. Karpenter consumes it. (Lesson #2)
#
#  💰 EKS control plane ~$0.10/hr + 1 NAT GW + 2× t3.medium.
#     `make down` when you're done. Full day ≈ $5–10.
# ══════════════════════════════════════════════════════════════════

locals {
  name = var.cluster_name
  tags = {
    project = "karpenter-acd-demo"
    talk    = "i-broke-karpenter-4-times"
  }
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# ── VPC ─────────────────────────────────────────────────────────────
# Private subnets carry the discovery tag (Break #3 deletes it out-of-
# band; `terraform apply` heals it — that's the point).
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = local.name
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.name # ← Break #3 target
  }

  tags = local.tags
}

# ── EKS ─────────────────────────────────────────────────────────────
# 2 small system nodes, TAINTED — demo workloads can't land on them,
# so every scale-up forces Karpenter to provision. That's the trick.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = local.name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {} # ← Break #1's hero (and victim)
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    system = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 2
      desired_size   = 2
      taints = {
        addons = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  # Karpenter discovers the node security group by this tag
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}

# ── Karpenter IAM + infra ───────────────────────────────────────────
# Controller role via Pod Identity, node role, SQS interruption queue,
# EKS access entry, and a PRE-CREATED instance profile (Lesson #2:
# IaC owns IAM — Karpenter never writes it).
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.37"

  cluster_name = module.eks.cluster_name

  enable_v1_permissions           = true
  enable_pod_identity             = true
  create_pod_identity_association = true # ← Break #1 deletes this out-of-band
  namespace                       = "kube-system"

  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "KarpenterNodeRole-${local.name}"
  create_instance_profile       = true # ← the profile Karpenter CONSUMES (Break #2)

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

# ── Karpenter controller (Helm) ─────────────────────────────────────
resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version
  wait       = true

  values = [yamlencode({
    settings = {
      clusterName       = module.eks.cluster_name
      interruptionQueue = module.karpenter.queue_name
    }
    controller = {
      resources = {
        requests = { cpu = "500m", memory = "512Mi" }
      }
    }
  })]

  depends_on = [module.karpenter]
}
