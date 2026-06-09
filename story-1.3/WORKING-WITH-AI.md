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

---

## §6 — Manual test session: deploying to eks-dev (2026-06-07/08)

Since GitHub Actions wasn't available (no real cluster at the time the story was written), I ran the deployment steps manually against a test cluster `eks-dev`. This section documents what I discovered.

### What we did step by step

1. **Gateway API CRDs** — `kubectl apply -f standard-install.yaml` succeeded immediately. ✅
2. **VPC setup** — The cluster's VPC (`vpc-0b565376502e4e506`) had no IPv6 CIDR. Added a `/56` block from Amazon pool (`2600:1f10:45f5:4000::/56`). Assigned `/64` sub-blocks to each of the 3 public subnets, and added `::/0 → igw` routes to their route tables.
3. **values.yaml** — Filled in `clusterName: eks-dev` and `vpcId: vpc-0b565376502e4e506`. The subnet tag `kubernetes.io/role/elb=1` was already on the public subnets.
4. **ALB Controller install** — `helm upgrade --install` with the IRSA role ARN (`arn:aws:iam::383585068161:role/alb-controller-irsa-eks-dev`) succeeded. Two pods running. ✅
5. **GatewayClass** — Controller v3.4.0 does NOT auto-create the `alb` GatewayClass. Also, the correct `controllerName` in v3.4.0 is `gateway.k8s.aws/alb`, NOT `eks.amazonaws.com/alb` (which is the old v2.x value, still in AWS docs). Created manually. ✅
6. **Gateway deploy** — Applied `gateway/gateway.yaml`. Gateway stuck in `Unknown`.

### Issues encountered

**Issue 1 — `ec2:DescribeRouteTables` missing from IRSA role**
Controller failed with `403 UnauthorizedOperation` on `DescribeRouteTables`. This permission is required by v3.4.0 to classify subnets as public/private. Fixed via Terraform update to the IRSA policy in the infra repo. The workflow-generated policy was missing this action.

**Issue 2 — GatewayClass controllerName changed in v3.x**
AWS docs still show `eks.amazonaws.com/alb` but v3.4.0 uses `gateway.k8s.aws/alb`. A GatewayClass with the wrong name stays in `Unknown` indefinitely with no error logged. Discovered by observing the controller's own internal name in startup logs.

**Issue 3 — `unable to resolve at least one subnet: 3 have insufficient available IP addresses`**
After fixing the IAM issue, a new error appeared. All 3 public subnets have 16,000+ free IPv4 addresses (/18 CIDRs), correct IGW routes, associated IPv6 CIDRs, and the `kubernetes.io/role/elb=1` + `kubernetes.io/cluster/eks-dev=shared` tags. The error persists regardless of:
- Whether subnets are specified by tag vs explicit IDs
- `ipv4` vs `dualstack` ip-address-type
- Presence or absence of a `LoadBalancerConfiguration` CRD
- Controller restarts

**Status at session end:** unresolved. v3.4.0 was released 2026-06-03 (5 days before this session). Likely a bug in the new Gateway API controller path. Next steps: try downgrading to v2.x (which also supports Gateway API from v2.7+) and re-test.

### Infrastructure gaps discovered

These were not in the Story 1.3 design but surfaced during manual testing:

| Gap | Fix applied |
|---|---|
| VPC had no IPv6 CIDR | Added `/56` from Amazon pool |
| Public subnets had no IPv6 CIDRs | Assigned `/64` sub-blocks to each |
| Public subnets missing `::/0 → igw` route | Added manually |
| `ec2:DescribeRouteTables` missing from IRSA policy | Fixed via Terraform |
| GatewayClass not auto-created by Helm chart | Must be created manually — add to workflow |
| GatewayClass `controllerName` changed in v3.x | `gateway.k8s.aws/alb`, update docs |

### What I learned about v3.4.0 vs v2.x

- v3.x introduced `LoadBalancerConfiguration`, `TargetGroupConfiguration`, `ListenerRuleConfiguration` CRDs — these replace annotations for Gateway API config. Annotations still work for Ingress.
- v3.x changed the GatewayClass controllerName from `eks.amazonaws.com/alb` to `gateway.k8s.aws/alb`.
- v3.x does not auto-create the GatewayClass via Helm even with `enableGatewayAPI: true`.
- The subnet resolver error message `insufficient available IP addresses` is misleading — it fires even when subnets have thousands of free IPs, suggesting it's a catch-all for multiple failure modes in v3.4.0.

---

## §7 — Debugging the subnet resolver: full investigation (2026-06-08)

This section documents the complete second debugging session, picking up from §6's unresolved Issue 3.

### The error

```
unable to resolve at least one subnet.
Evaluated 3 subnets: 0 are tagged for other clusters, and 3 have insufficient available IP addresses
```

All 3 public subnets have 16,000+ available IPv4 IPs. The threshold in the source code is 8. The math should pass. It doesn't.

### What we tried (all failed)

Every variation below was tried while the error persisted unchanged:

| What we tried | Why we thought it might help | Result |
|---|---|---|
| Explicit subnet IDs in Gateway annotation | Bypass tag-based discovery | Still "3 insufficient IPs" |
| `ipv4` instead of `dualstack` ip-address-type | Rule out IPv6 availability check | Still "3 insufficient IPs" |
| `LoadBalancerConfiguration` CRD with explicit subnet IDs | Use v3.x-native subnet config path | Still "3 insufficient IPs" |
| `LoadBalancerConfiguration` with tag selector | Use `ResolveViaSelector` path instead | Still "3 insufficient IPs" |
| Downgrade controller to v3.3.0 | Rule out v3.4.0-specific regression | Still "3 insufficient IPs" |
| Downgrade controller to v2.17.1 | Try v2.x code path entirely | `ALBGatewayAPI=false` by default in v2.x |
| Enable `AssignIpv6AddressOnCreation` on subnets | Rule out IPv6 attribute check | Still "3 insufficient IPs" |
| Disable `SubnetDiscoveryByReachability` feature gate | Bypass route-table-based discovery | Found **0 subnets** instead (broke discovery entirely) |
| Upgrade Gateway API CRDs from v1.2.1 to v1.5.0 | Fix version mismatch per gotcha #2 | Still "3 insufficient IPs" |
| `scheme: internet-facing` in LBC | Rule out scheme defaulting to `internal` | Still "3 insufficient IPs" |
| Full controller uninstall + reinstall | Clear any in-memory cache | Still "3 insufficient IPs" |
| Debug logging (`--log-level=debug`) | Get per-subnet detail | No additional detail logged at the subnet check level |

### Key diagnostic finding

A test Ingress resource with the same explicit subnet IDs **worked**: the controller successfully built a model, resolved all 3 public subnets (16,000+ IPs), and moved on to the deploy stage. This proved:

- The subnet resolver itself is not broken
- The EC2 API is returning correct data to the controller
- The 3 subnets genuinely have sufficient IPs
- The problem is **specific to the Gateway API reconcile path**, not the shared resolver

### The source code analysis

AI fetched the v3.3.0 source code and confirmed:
- `isSubnetContainsSufficientIPAddresses` checks `AvailableIpAddressCount >= 8` — the same for both Ingress and Gateway paths
- `ResolveViaDiscovery` does call `DescribeSubnets` and gets full objects (not partial data from route tables)
- The `LoadBalancerConfiguration` CRD is the correct v3.x mechanism for Gateway subnet config
- The Go module imports `sigs.k8s.io/gateway-api v1.5.0` — meaning v3.3.0 requires CRD version **v1.5.0**, not v1.2.1 that we had installed

### The CRD version mismatch (gotcha #2 — almost the answer)

The Gateway API CRDs installed from step 1 were **v1.2.1** (standard channel). The controller v3.3.0 was built against **v1.5.0**. This was exactly the pairing mismatch Story 1.3's gotchas warn about: *"Pick the channel and pin the controller version together"*.

After upgrading CRDs to v1.5.0 — the error persisted. The version mismatch was a real problem but not the root cause of the subnet error.

### The actual root cause

In v3.x Gateway API, the `LoadBalancerConfiguration` CRD is **not linked to a Gateway by name match**. The controller does not auto-discover an LBC named `team-gateway` for a Gateway named `team-gateway`. The link must be explicit via `spec.infrastructure.parametersRef` in the Gateway spec:

```yaml
spec:
  infrastructure:
    parametersRef:
      group: gateway.k8s.aws
      kind: LoadBalancerConfiguration
      name: team-gateway
```

Without this reference:
1. The controller ignores the LBC entirely
2. Falls back to `ResolveViaDiscovery` with default options
3. `ResolveViaDiscovery` uses `SubnetDiscoveryByReachability` to classify subnets by route tables
4. For reasons not fully understood, it evaluates the 3 **private** IPv6-only subnets (which have `AvailableIpAddressCount = 0`) rather than the public ones
5. All 3 fail the `>= 8` IP check → misleading "insufficient available IP addresses" error

### What fixed it

```yaml
# gateway/gateway.yaml — added infrastructure.parametersRef
spec:
  infrastructure:
    parametersRef:
      group: gateway.k8s.aws
      kind: LoadBalancerConfiguration
      name: team-gateway
```

```yaml
# LoadBalancerConfiguration — required fields
spec:
  scheme: internet-facing
  ipAddressType: dualstack
  loadBalancerSubnets:
    - identifier: subnet-0f4c64bc15861e726
    - identifier: subnet-00e3df91a56eb9515
    - identifier: subnet-0c159a3734c968b6d
```

With `parametersRef` set, the controller uses the LBC's `loadBalancerSubnets` directly via `ResolveViaNameOrIDSlice`, which correctly calls `DescribeSubnets` with explicit IDs and gets `AvailableIpAddressCount = 16,000+`.

**Result:** Gateway `PROGRAMMED: True`, ALB address assigned: `k8s-platform-teamgate-41e6b79100-558783643.us-east-1.elb.amazonaws.com` ✅

### What the story manifests need to change

The `gateway/gateway.yaml` in this repo was written without knowing `parametersRef` is required. It must be updated to include `spec.infrastructure.parametersRef`. The `LoadBalancerConfiguration` manifest needs to be added as a new file that gets applied before the Gateway.

The GitHub Actions workflow also needs a step to apply the LBC CRD before the Gateway.

### Updated infrastructure gaps table

| Gap | Fix applied |
|---|---|
| Gateway API CRDs were v1.2.1, controller requires v1.5.0 | Upgrade CRDs in workflow to match pinned controller version |
| `LoadBalancerConfiguration` CRD not created by workflow | Add manifest + apply step before Gateway |
| Gateway `spec.infrastructure.parametersRef` missing | Required in v3.x for LBC to be used — add to `gateway.yaml` |
| `alb.ingress.kubernetes.io/subnets` annotation ignored for Gateway | Not read in v3.x Gateway path; subnet config belongs in LBC only |

### Time spent debugging

~8 hours across two sessions. The key lessons:

1. **Read the gotchas first.** Gotcha #2 (CRD channel/version pairing) directly called out this class of problem.
2. **Test the Ingress path as a diagnostic.** The moment Ingress worked and Gateway didn't, the problem became "what does Gateway do differently?" instead of "why don't my subnets work?"
3. **The error message is a red herring.** "Insufficient available IP addresses" does not mean the subnets lack IPs — it means the resolver code path reached the IP check with the wrong subnets or wrong resolver path.
