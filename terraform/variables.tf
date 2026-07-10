variable "region" {
  description = "AWS region (Mumbai — close to Bengaluru)"
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "karpenter-acd-demo"
}

variable "kubernetes_version" {
  description = "EKS version"
  type        = string
  default     = "1.33"
}

variable "karpenter_version" {
  description = "Karpenter chart version"
  type        = string
  default     = "1.13.0"
}
