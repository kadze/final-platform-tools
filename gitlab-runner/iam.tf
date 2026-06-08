data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

locals {
  oidc_issuer = trimprefix(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://")
}

resource "aws_iam_role" "gitlab_runner_job" {
  name = "gitlab-runner-job-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_issuer}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_issuer}:sub" = "system:serviceaccount:gitlab-runner:gitlab-runner"
            "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Project = "mrp25-ubuntu"
    Story   = "4.1"
    Purpose = "GitLab CI job pods - IRSA"
  }
}

resource "aws_iam_policy" "gitlab_runner_job_packer" {
  name   = "gitlab-runner-job-policy-packer-ec2"
  policy = templatefile("${path.module}/policies/packer-ec2.json", {})
}

resource "aws_iam_policy" "gitlab_runner_job_state" {
  name   = "gitlab-runner-job-policy-terraform-state"
  policy = templatefile("${path.module}/policies/terraform-state-s3.json", { bucket_name = var.terraform_state_bucket })
}

resource "aws_iam_role_policy_attachment" "gitlab_runner_job_packer" {
  role       = aws_iam_role.gitlab_runner_job.name
  policy_arn = aws_iam_policy.gitlab_runner_job_packer.arn
}

resource "aws_iam_role_policy_attachment" "gitlab_runner_job_state" {
  role       = aws_iam_role.gitlab_runner_job.name
  policy_arn = aws_iam_policy.gitlab_runner_job_state.arn
}

output "gitlab_runner_job_role_arn" {
  description = "ARN of the IAM role assumed by GitLab runner job pods via IRSA"
  value       = aws_iam_role.gitlab_runner_job.arn
}
