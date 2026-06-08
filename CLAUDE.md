# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

Two-phase setup for an AWS EKS cluster and its platform tooling:

1. **Phase 1 — Cluster creation**: CloudFormation stacks via `eksctl` + the `Makefile` in `eks-cloudformation/`. Triggered manually via the `eks-setup-manual-trigger.yaml` workflow.
2. **Phase 2 — Tool deployment**: GitHub Actions workflow `deploy-platform-tools.yaml` runs on every push to `main` or `feature/**` and applies platform tools (ingress-nginx, Karpenter, logging, monitoring, external-dns, K8s user roles) to the running cluster.

## Key Commands

### Create the EKS cluster (run from `eks-cloudformation/`)

```bash
# Full cluster creation — provisions CloudFormation stacks for IAM, VPC, control plane, node group, and OIDC+EBS-CSI
make cluster name=temporary-eks-cluster-dev version=1.34 role=<SSO_ADMIN_ROLE_NAME>

# Connect kubectl to the cluster
make update-kubeconfig name=temporary-eks-cluster-dev

# Tear down node group only
make delete-workers name=temporary-eks-cluster-dev

# Tear down full cluster
make delete-eks name=temporary-eks-cluster-dev
```

### Deploy ingress-nginx manually

```bash
kubectl apply -f ingress-nginx/deploy.yaml
```

### State buckets (one-time manual setup, not CI-managed)

```bash
cd state-buckets-manual
terraform init
terraform apply   # creates S3 bucket + DynamoDB lock table
```

### GitLab runner IAM (Terraform, run from `gitlab-runner/`)

```bash
terraform init
terraform apply -var="cluster_name=<cluster>" -var="terraform_state_bucket=<bucket>"
```

## Architecture

### Cluster setup flow

The `Makefile` `cluster` target runs these CloudFormation stacks in order:
1. `cfn-secret-provider` — Lambda-backed custom resource for secrets
2. `eks-node-secrets` — SSH key pair for worker nodes stored in SSM
3. `<name>-iam` — NodeInstanceProfile and NodeInstanceRole
4. `<name>` — VPC, subnets (3 AZs), EKS control plane
5. `<name>-workers` — Managed node group (Spot, t3.medium by default)
6. OIDC provider + EBS CSI driver addon via `eksctl`

Network and node sizing defaults live in `eks-cloudformation/cluster_config` — edit there to change VPC CIDRs, instance type, or ASG bounds before running `make cluster`.

### Platform tools workflow

`deploy-platform-tools.yaml` authenticates to AWS via OIDC (`vars.IAM_ROLE` from the `dev` GitHub environment), calls `aws eks update-kubeconfig`, then runs each tool's deployment step. Currently only ingress-nginx is wired up; the Karpenter, logging, monitoring, external-dns, and K8s roles steps contain placeholder `echo` commands to be replaced.

**Important**: The workflow currently targets `temporary-eks-cluster-${ENVIRONMENT_STAGE}`. Once the permanent cluster is provisioned via the `terraform-infra-25c-ubuntu` project, update the `Login to EKS` step to reference the permanent cluster name.

### GitLab runner

`gitlab-runner/` contains two independent parts:
- `iam.tf` — Terraform that creates an IRSA role (`gitlab-runner-job-role`) trusted by the cluster's OIDC provider, allowing runner job pods to assume the role without static credentials. Requires `cluster_name` and `terraform_state_bucket` variables.
- `values.yaml` — Helm values for the `gitlab/gitlab-runner` chart. Set `runnerToken` before deploying.

### State bucket

`state-buckets-manual/buckets.tf` creates the S3 bucket and DynamoDB lock table used by all other Terraform in this project. It intentionally has no remote backend — apply it locally once and treat the resources as manually managed.

## CI/CD

- **Auth**: GitHub Actions uses OIDC (`role-to-assume: ${{ vars.IAM_ROLE }}`). No long-lived AWS credentials.
- **Region**: `us-east-1` (hardcoded in both workflows).
- **Merge requirement**: minimum 3 approvals (CODEOWNERS: `@312School/final-project-managers`).
- **PR template**: link a Jira ticket at `https://312school.atlassian.net/browse/<ticket>`.
- **Never run `kubectl apply` or `terraform apply` manually** outside of GitHub Actions except for the one-time state bucket setup.
