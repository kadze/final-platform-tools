# WORKING-WITH-AI.md — Story 1.3

**Engineer:** Andrii Shevtsov  
**Story:** 1.3 — Traffic Plane Migration (ingress-nginx → Gateway API)

---

## §1 — What I used AI for

I used Claude Code to help build out the full Story 1.3 delivery across both repos. Specifically:

- **Terraform module** (`modules/alb-controller-irsa/`): structuring the IRSA trust policy, writing the least-privilege IAM policy for the ALB controller
- **Repo restructure**: migrating from `roots/devops-project-main/` + tfvars to the `roots/environments/{dev,staging,production}/` root-per-env shape the team conventions require
- **Platform-tools manifests**: the Helm values for the AWS Load Balancer Controller, the shared Gateway resource with the correct ALB annotations for a dual-stack IPv6-primary cluster
- **Documentation**: the HTTPRoute conventions doc, migration plan, cutover ledger, and this README — I directed the structure and content; AI drafted and I reviewed
- **Cutover PR manifests**: HTTPRoute manifests for the three app teams, based on the service and hostname patterns from each app's story spec

---

## §2 — What it got right

- **IPv6 + ALB target type reasoning**: When I described the cluster topology (IPv6 pods, private nodes, public dual-stack subnets), AI correctly identified that `ip` target type is required — `instance` target type would fail because nodes have no reachable IPv4 address, and the ALB needs to register pod IPs directly. It also correctly separated `ip-address-type: dualstack` (the ALB's frontend address family) from `target-type: ip` (how it reaches backends) — these are independent and easy to conflate.
- **Terraform conventions**: when I explained the root-per-env shape, S3 native locking (`use_lockfile = true`), and no-community-modules rule, it applied them consistently across all three env roots without drifting back to old patterns.
- **IRSA trust policy scope**: the trust policy is correctly scoped to the exact namespace + service account name via OIDC `StringEquals` conditions — not a wildcard that would let any service account in the cluster assume the role.
- **Workflow step order**: identified without prompting that Gateway API CRDs must install before the controller, because the controller's startup depends on them.

---

## §3 — What it got wrong / what I had to fix

- **`dynamodb_table` in the initial backend config**: the first draft of `providers.tf` included `dynamodb_table = "terraformlock"` from the existing scaffold. I corrected this — the convention is `use_lockfile = true` (S3 native locking, no DynamoDB). AI had picked up the pattern from the existing file rather than the convention I stated.
- **Cutover PR service names and ports**: the HTTPRoute manifests for 3.1, 3.3, and 3.5 use assumed service names (`versus-backend`, `proshop-frontend`, etc.) and ports (5000, 80, 3000) based on typical patterns for each stack. These are not verified against the actual Helm charts because the app repos don't exist yet. Every manifest has a comment calling this out explicitly — these must be verified before the PR is submitted.
- **Team domain placeholder**: used `312ubuntu.com` as the team domain based on the pattern in the project spec (`312centos.com` for the centos team). If the actual team domain is different, all three HTTPRoute hostnames need updating.

---

## §4 — What I verified before shipping

- **Workflow step sequencing**: confirmed the three new steps in `deploy-platform-tools.yaml` are in the right order (CRDs → controller → Gateway) and that the ingress-nginx step is preserved above them, not replaced.
- **IRSA trust policy conditions**: read the trust policy JSON in `modules/alb-controller-irsa/resources.tf` and confirmed both `sub` and `aud` conditions are present and scoped to the correct service account — a missing `aud` condition is a common mistake that allows any OIDC-authenticated workload to assume the role.
- **Backend config**: confirmed `use_lockfile = true` and no `dynamodb_table` in all three env roots' `providers.tf`.
- **Gateway `allowedRoutes`**: confirmed `from: All` is set on the shared Gateway listener — without this, HTTPRoutes in other namespaces cannot attach to the Gateway and will silently not work.
- **Dummy modules preserved**: confirmed all three env roots call `dummy-module-1` and `dummy-module-2` per the CLAUDE.md instruction not to remove them.
- **`ip` target type annotation on Gateway**: confirmed `alb.ingress.kubernetes.io/target-type: ip` is set — this is the critical annotation for IPv6 pod reachability and easy to forget if you copy from IPv4 cluster examples.

---

## §5 — What I would do differently

The two values I had to leave as placeholders (`VPC_ID_PLACEHOLDER` and the OIDC cluster ID) would ideally come from Story 1.1's Terraform outputs. In a real engagement I would coordinate with the 1.1 owner early to agree on which outputs they expose, so the infra repo wiring can reference them directly rather than requiring manual substitution. For this project the dependency ordering meant those values weren't available when I wrote the module.
