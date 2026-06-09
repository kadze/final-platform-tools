# Karpenter

## Overview and Architecture

Karpenter is an open-source node autoscaler for Kubernetes. Instead of managing node groups, it provisions EC2 instances directly in response to pending pods and deprovisions them when no longer needed.

This deployment includes:
- **Karpenter controller** — installed via Helm into the `karpenter` namespace (version `1.4.0`)
- **EC2NodeClass** — defines how nodes are launched (AMI: AL2023, IAM role, subnets, security groups, instance types: `t3.medium`, `t3a.medium`)
- **NodePool** — defines workload constraints and consolidation behavior (consolidation window: 5 minutes)

The controller uses IRSA (IAM Roles for Service Accounts) via `karpenter-controller-<cluster-name>` to call AWS APIs for node provisioning.

## Prerequisites

The following must be in place in `terraform-infra-25c-ubuntu` before deploying:

- `karpenter-controller-<cluster-name>` IAM role with required EC2, IAM, SQS, and SSM permissions
- `karpenter-node-<cluster-name>` IAM role with EKS worker node policies
- SQS interruption queue (`karpenter-<cluster-name>`)
- EventBridge rules for spot interruption, rebalance, instance state, and health events
- Subnets tagged with `karpenter.sh/discovery: <cluster-name>`
- Node security group tagged with `karpenter.sh/discovery: <cluster-name>`
- EKS access entry for `SharedGHATerraformRole` with `AmazonEKSClusterAdminPolicy`

## How to Run/Execute

Karpenter is deployed automatically via the GitHub Actions workflow on push to `feature/**` or `main`.

To deploy manually:
```bash
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "1.4.0" \
  --namespace karpenter --create-namespace \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_CONTROLLER_ROLE_ARN}" \
  --set settings.clusterName="${CLUSTER_NAME}" \
  --set settings.interruptionQueue="karpenter-${CLUSTER_NAME}" \
  --wait

envsubst < karpenter/ec2nodeclass.yaml | kubectl apply -f -
kubectl apply -f karpenter/nodepool.yaml
```

To verify:
```bash
kubectl get pods -n karpenter
kubectl get ec2nodeclass
kubectl get nodepool
kubectl get nodeclaims
```

## Issues

### 1. GitHub Actions role missing EKS access entry — PENDING
`SharedGHATerraformRole` was not in the EKS access entries, causing `kubectl`/`helm` to fail with "Kubernetes cluster unreachable". Added manually in the console as a temporary fix. Needs to be captured in Terraform in `terraform-infra-25c-ubuntu`.

### 2. Karpenter controller missing IAM instance profile permissions — RESOLVED
`karpenter-controller-<cluster-name>` was missing `iam:GetInstanceProfile` and related instance profile permissions. Fixed by adding them to the controller policy in `terraform-infra-25c-ubuntu`.

### 3. Subnets missing discovery tag — PENDING
Subnets were missing the `karpenter.sh/discovery: <cluster-name>` tag. Tagged manually as a temporary fix. Needs to be added via Terraform in `terraform-infra-25c-ubuntu` (VPC/subnet configuration).

### 4. Node security group missing discovery tag — PENDING
The node security group was missing the `karpenter.sh/discovery: <cluster-name>` tag. Tagged manually as a temporary fix. Needs to be added via Terraform in `terraform-infra-25c-ubuntu`.

### 5. Nodes provisioned but not joining the cluster — TEMPORARY FIX
`eks-dev` has public subnets only. Karpenter-provisioned nodes launched without public IPs and could not reach the EKS API endpoint. Fixed by adding `associatePublicIPAddress: true` to the EC2NodeClass. Remove this when switching to the permanent cluster with private subnets and NAT gateway.

### 6. SharedGHATerraformRole missing SQS and EventBridge permissions — PENDING
Terraform plan failed because the role lacked `sqs:*` and `events:*` permissions needed to manage the Karpenter interruption queue and EventBridge rules. Added manually to the policy as a temporary fix. Needs to be captured in Terraform in `terraform-infra-25c-ubuntu`.

## Resources

- [Karpenter Documentation](https://karpenter.sh/docs/)
- [Karpenter AWS Provider](https://github.com/aws/karpenter-provider-aws)
- [EC2NodeClass Reference](https://karpenter.sh/docs/concepts/nodeclasses/)
- [NodePool Reference](https://karpenter.sh/docs/concepts/nodepools/)
