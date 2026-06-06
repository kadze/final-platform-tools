# Platform Tools Repository

## Overview
This repository is structured to support the deployment and management of various DevOps and platform tools, primarily focused on Amazon EKS.

## Repository Structure
- `karpenter/`: Configurations for Karpenter node provisioning.
- `eks-cloudformation/`: CloudFormation templates for EKS cluster creation.
- `eks-logging/`: Logging tools for EKS.
- `eks-monitoring/`: Monitoring tools for EKS.
- `external-dns/`: Configuration for External DNS setup in Kubernetes.
- `k8s-user-roles/`: Kubernetes user roles and permissions setup.
- `state-buckets-manual/`: Terraform configurations for manually setting up state buckets.

## Contribution Guidelines
- Stick to the existing repository structure for consistency and ease of navigation.
- All code should be merged into the main branch. A minimum of 3 approvals is required for each merge to ensure code quality and collaborative review.
- Avoid manual deployments as much as possible. All deployments should be executed through GitHub Actions.

## GitHub Actions
This repository uses two main GitHub Actions workflows:
1. `eks-setup-manual-trigger.yaml`: Manually triggered workflow for setting up the EKS cluster using CloudFormation.
2. `deploy-platform-tools.yaml`: Automatically triggered on pushes to the main and feature branches, deploying various platform tools.

### Adding Steps to deploy-platform-tools.yaml
- Add your own steps to the `deploy-platform-tools.yaml` workflow for deploying additional tools or updates.

## Access and Permissions
- Both the `AWSReservedSSO_Administrator-*` role and the IAM role running the GitHub Actions job should have full access to the EKS cluster created via CloudFormation.
- Once the cluster is established through Terraform, adjust the workflow YAML to use the newly created cluster.

## Final Notes
- Ensure all deployments and configurations are well-documented.
- Regularly update the README files in each directory with relevant information, including issues faced and resources used.
## Working with AI — your memoir (deliverable)

This repo includes the memoir template at [`docs/working-with-ai-template.md`](docs/working-with-ai-template.md). Copy it into your story folder as `WORKING-WITH-AI.md` and fill it in **as you work** — it is a required deliverable for your primary story, and the artifact that pays you back at interview time.
