output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "karpenter_node_role_name" {
  value = module.karpenter.node_iam_role_name
}

output "karpenter_node_role_arn" {
  value = module.karpenter.node_iam_role_arn
}

output "karpenter_instance_profile_name" {
  description = "Pre-created instance profile — Karpenter CONSUMES it, never writes IAM"
  value       = module.karpenter.instance_profile_name
}

output "karpenter_controller_role_name" {
  description = "Controller role (Break #2 attaches an explicit-deny here to simulate an SCP)"
  value       = module.karpenter.iam_role_name
}

output "karpenter_controller_role_arn" {
  value = module.karpenter.iam_role_arn
}

output "private_subnet_ids" {
  description = "Break #3 strips the discovery tag from these; terraform apply heals"
  value       = module.vpc.private_subnets
}
