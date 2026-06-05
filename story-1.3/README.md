# Story 1.3 — Traffic Plane Migration (ingress-nginx → Gateway API)

**Assignee:** Andrii Shevtsov  
**Branch:** `feature/1.3-ingress-to-Gateway-API`  
**Status:** In Progress

---

## What this story delivers

Migrates the team's traffic plane from ingress-nginx + classic `Ingress` resources onto **Gateway API on the AWS Load Balancer Controller**, without downtime. Runs both planes in parallel during the migration window, then decommissions ingress-nginx once all three app teams have cut over.

---

## Architecture

```
Internet
   │
   ▼
AWS ALB (internet-facing, dual-stack)
   │  ← provisioned by AWS Load Balancer Controller
   │  ← lives in public dual-stack LB-only subnets (Story 1.1)
   ▼
Gateway: team-gateway (platform-tools namespace)
   │  ← HTTP listener, port 80
   │  ← allowedRoutes: All namespaces
   ▼
HTTPRoute (in app namespace)
   │  ← submitted by each app team (or via 1.3 cutover PRs)
   ▼
Backend Service → Pod (IPv6 address)
   │  ← ip target type: ALB routes directly to pod IPv6 address
   │  ← bypasses kube-proxy entirely
```

**Why ip target type on an IPv6 cluster:**  
Pods get IPv6 addresses. Nodes sit in private IPv6-only subnets. The ALB is in public dual-stack subnets (IPv4 + IPv6). With `ip` target type the ALB registers pod IPs directly into the target group — so it reaches pods over IPv6 without needing NAT or a NodePort. `instance` target type would not work here because nodes have no public IPv4.

**Why dualstack on the ALB:**  
ALB clients (browsers, mobile apps) typically come in over IPv4. The ALB's dualstack address means it accepts both IPv4 and IPv6 clients. Traffic from the ALB to pods is always over IPv6 (the pod IP is IPv6). This is the correct topology for an IPv6-primary cluster.

---

## Files this story owns

| Path | What it is |
|---|---|
| `aws-load-balancer-controller/values.yaml` | Helm values for the controller install |
| `gateway/gateway.yaml` | `platform-tools` namespace + shared `team-gateway` |
| `docs/httproute-conventions.md` | Hostname/attachment contract for app teams |
| `docs/migration-plan.md` | Parallel-run window, rollback, decommission |
| `docs/cutover-ledger.md` | Per-app cutover status (3.1 / 3.3 / 3.5) |
| `cutover-prs/3.1-versus/httproute.yaml` | HTTPRoute to submit into Versus branch |
| `cutover-prs/3.3-proshop/httproute.yaml` | HTTPRoute to submit into Proshop branch |
| `cutover-prs/3.5-weather/httproute.yaml` | HTTPRoute to submit into Weather branch |
| `story-1.3/README.md` | This file |
| `story-1.3/WORKING-WITH-AI.md` | AI memoir |

The controller IAM role lives in `terraform-infra-25c-ubuntu`:  
`modules/alb-controller-irsa/` — called from `roots/environments/dev/main.tf`

---

## How to deploy

Everything runs through `deploy-platform-tools.yaml`. No manual `kubectl` or `helm` from a laptop.

**Required GitHub Actions variables (set on the `dev` environment):**

| Variable | Value |
|---|---|
| `ALB_CONTROLLER_IAM_ROLE_ARN` | ARN of the IRSA role created by `modules/alb-controller-irsa` in the infra repo |

**Required placeholder values to fill in before deploying:**

| File | Placeholder | Where to get the value |
|---|---|---|
| `aws-load-balancer-controller/values.yaml` | `VPC_ID_PLACEHOLDER` | Output from Story 1.1 VPC Terraform module |
| `roots/environments/dev/main.tf` (infra repo) | `CLUSTER_OIDC_ID_DEV` | EKS cluster → Configuration → OIDC endpoint in AWS console |
| `roots/environments/dev/main.tf` (infra repo) | `ACCOUNT_ID` | `aws sts get-caller-identity --query Account` |

**Deploy order within the workflow:**

1. Gateway API CRDs (must come first — controller depends on them)
2. AWS Load Balancer Controller (registers the `alb` GatewayClass)
3. Shared Gateway (depends on the GatewayClass existing)

---

## How to verify after deploy

```bash
# Controller is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# GatewayClass registered by the controller
kubectl get gatewayclass alb

# Gateway is accepted and an ALB was provisioned
kubectl get gateway team-gateway -n platform-tools
# STATUS column should show: Accepted

# Get the ALB DNS name for smoke testing
kubectl get gateway team-gateway -n platform-tools -o jsonpath='{.status.addresses[0].value}'
```

Smoke test an HTTPRoute once it exists:
```bash
curl -H "Host: versus-ubuntu-dev.312ubuntu.com" http://<alb-dns>/
```

---

## Cutover status

See `docs/cutover-ledger.md` for per-app status.  
See `docs/migration-plan.md` for the decommission gate — ingress-nginx stays until all three apps confirm.

---

## Issues faced

- **IPv6 pod reachability**: `instance` target type routes to node IP + NodePort, which only works when nodes have a reachable IPv4 address. On this IPv6-primary cluster nodes have no public IPv4, so `ip` target type is required — ALB registers pod IPs directly.
- **dualstack ALB + IPv6-primary cluster**: The ALB itself needs dual-stack (IPv4 + IPv6 frontend) because most internet clients arrive over IPv4. But the path from the ALB to pods is purely IPv6 (pod IPs). These are independent settings — `ip-address-type: dualstack` on the ALB, `target-type: ip` for the backends.
- **Subnet auto-discovery**: The ALB controller discovers subnets by the `kubernetes.io/role/elb=1` tag. Story 1.1 must tag the public dual-stack subnets with this tag — if ALB creation fails with "no subnets found", that tag is missing.
- **Gateway API CRDs before controller**: The controller startup will fail if Gateway API CRDs are not installed first. Workflow step order matters.
