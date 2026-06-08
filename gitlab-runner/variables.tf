variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region to deploy resources into"
}

variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster — used to look up the OIDC issuer for the IRSA trust policy"
}

variable "terraform_state_bucket" {
  type        = string
  description = "Name of the shared S3 state bucket. Set in terraform.tfvars."
}
