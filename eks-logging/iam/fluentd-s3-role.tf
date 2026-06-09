locals {
  oidc_issuer = "oidc.eks.us-east-1.amazonaws.com/id/C518D5CB1A79656432948AE2225FA67D"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_role" "fluentd_s3" {
  name = "fluentd-s3-role-25c-ubuntu"

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
            "${local.oidc_issuer}:sub" = "system:serviceaccount:logging:fluentd"
          }
        }
      }
    ]
  })

  tags = {
    Team      = "25c-ubuntu"
    Story     = "2.2"
    ManagedBy = "terraform"
  }
}

resource "aws_iam_policy" "fluentd_s3" {
  name        = "fluentd-s3-policy-25c-ubuntu"
  description = "Allows Fluentd to write logs to S3 and read them back for verification"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::383585068161-state-bucket-dev",
          "arn:aws:s3:::383585068161-state-bucket-dev/logs/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "fluentd_s3" {
  role       = aws_iam_role.fluentd_s3.name
  policy_arn = aws_iam_policy.fluentd_s3.arn
}

output "fluentd_role_arn" {
  value       = aws_iam_role.fluentd_s3.arn
  description = "Paste this ARN into the fluentd ServiceAccount annotation"
}
