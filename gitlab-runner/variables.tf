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
  default     = "383585068161-state-bucket-dev"
  description = "Name of the shared S3 state bucket created by Story 1.1. Update this value once the bucket has been provisioned by that story."
}
