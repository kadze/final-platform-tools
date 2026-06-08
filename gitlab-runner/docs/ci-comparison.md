# CI System Comparison — GitHub Actions vs GitLab CI

## Overview

This project runs both GitHub Actions and GitLab CI on the same EKS cluster. That's not how most teams operate — usually you pick one. Here it's intentional: GitHub Actions is the primary CI for all infrastructure deployments in this repo, and GitLab CI was deployed as part of Story 4.1 to prove we can operate a second CI platform on the same cluster. The goal is to demonstrate that the cluster can support multiple workloads from different CI systems, and to give the team hands-on experience with GitLab's Kubernetes executor in a real AWS environment.

## How Each System Triggers

**GitHub Actions** is triggered by pushes or pull requests to GitHub repositories. Jobs are picked up by GitHub's own infrastructure (or self-hosted runners if configured). No runner management needed for the default case.

**GitLab CI** is triggered by pushes to GitLab repositories. It requires a runner process to be running somewhere and polling GitLab for jobs. In this project, that runner is deployed as a Helm release into the `gitlab-runner` namespace on `eks-dev`. It uses the Kubernetes executor, so it doesn't run jobs on the runner pod itself — it spawns a new pod per job.

## Execution Model

**GitHub Actions** jobs run on GitHub-hosted VMs (`ubuntu-latest`, etc.) that are provisioned fresh per job and torn down after. Ephemeral by default, no infrastructure to maintain.

**GitLab CI (this project)** uses the Kubernetes executor. Every job that fires creates a fresh pod in the `gitlab-runner` namespace on `eks-dev`. The pod runs the job and is destroyed when it completes. This gives the same ephemeral-environment guarantee as GitHub-hosted runners, but on infrastructure we control. Concurrency is real: with `concurrent: 4` set in `values.yaml`, up to 4 jobs can run as simultaneous pods on the cluster at the same time.

## AWS Credentials Approach

**GitHub Actions** uses OIDC directly with AWS via the `aws-actions/configure-aws-credentials` action. GitHub's OIDC provider (`token.actions.githubusercontent.com`) issues a short-lived token, and AWS STS exchanges it for temporary credentials scoped to the assumed IAM role. No secrets stored anywhere.

**GitLab CI (this project)** uses IRSA (IAM Roles for Service Accounts). Job pods run as the `gitlab-runner` Kubernetes service account in the `gitlab-runner` namespace. The EKS OIDC provider is configured to trust that specific service account, and the `gitlab-runner-job-role` IAM role has a trust policy that allows `sts:AssumeRoleWithWebIdentity` for exactly that identity. The pod gets temporary AWS credentials injected automatically via the AWS SDK credential chain. No static credentials in GitLab CI variables or Kubernetes secrets.

## IAM Boundary

**GitHub Actions**: the IAM role is trusted by GitHub's OIDC provider and scoped to a specific repository and GitHub environment (`dev`). The trust policy uses `token.actions.githubusercontent.com` as the federated principal.

**GitLab CI**: the IAM role (`gitlab-runner-job-role`) is trusted by this cluster's OIDC provider:
```
oidc.eks.us-east-1.amazonaws.com/id/C518D5CB1A79656432948AE2225FA67D
```
The trust condition is scoped to exactly one service account in one namespace:
```
system:serviceaccount:gitlab-runner:gitlab-runner
```
Two policies are attached:
- **packer-ec2**: EC2 permissions needed for Packer AMI builds (Story 3.2 — Zarina's pipeline)
- **terraform-state-s3**: S3 read/write scoped to the `gitlab-runner/*` prefix on `383585068161-state-bucket-dev`

Neither system has static AWS credentials stored anywhere.

## When You Would Choose One Over the Other

**GitHub Actions** is the simpler choice for most teams. No runner infrastructure to manage, tight GitHub integration, and the free tier covers a lot of usage. Good default if the team is already on GitHub and doesn't need jobs to run inside a private network.

**GitLab CI** makes more sense if the organisation is already on GitLab, or if you need runners inside a private VPC (e.g. jobs that talk to internal databases or private endpoints). The Kubernetes executor gives full pod-level isolation per job, and you have complete control over the runner environment — custom images, resource limits, node selectors, all configurable in `values.yaml` and the runner config.

## Why Both in This Project

GitHub Actions is the team's primary CI. Every deployment in this repo — ingress-nginx, platform tools, EKS cluster setup — goes through `deploy-platform-tools.yaml` and `eks-setup-manual-trigger.yaml`. That's not changing.

GitLab CI is here specifically because Story 4.1 required deploying a second CI system onto the cluster. The concrete use case is Story 3.2 (Zarina): Packer AMI builds and Terraform runs that are triggered from GitLab rather than GitHub. Rather than route that work through GitHub Actions, we stood up a GitLab runner on the same cluster so those pipelines can run with proper AWS credentials via IRSA, without needing a separate runner VM or hardcoded secrets.

## References

| Item | Detail |
|---|---|
| Runner namespace | `gitlab-runner` on `eks-dev` |
| Helm values | `gitlab-runner/values.yaml` |
| IAM Terraform | `gitlab-runner/iam.tf` |
| IAM role ARN | `arn:aws:iam::383585068161:role/gitlab-runner-job-role` |
| State bucket | `383585068161-state-bucket-dev` (prefix: `gitlab-runner/*`) |
| EKS OIDC ID | `C518D5CB1A79656432948AE2225FA67D` |
