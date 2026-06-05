# Migration Plan: ingress-nginx → Gateway API

Traffic plane migration for the dev cluster.  
Owner: Story 1.3 · Status: in progress

---

## Guiding principle

Both traffic planes run in parallel until every app has migrated. No app is cut over until its HTTPRoute is verified end-to-end. ingress-nginx is not removed until the cutover ledger shows all three apps confirmed.

---

## Phase 1 — Parallel-run window

**What runs simultaneously**

| Component | How traffic reaches it |
|---|---|
| ingress-nginx | Existing `Ingress` objects, unchanged |
| AWS Load Balancer Controller | New `HTTPRoute` objects, new ALB |
| Shared `team-gateway` | HTTP only, port 80 |

**What this means for app teams**

- Existing Ingress objects are not touched. Apps continue to serve traffic through ingress-nginx with zero disruption.
- Each app team submits a cutover PR that adds an HTTPRoute alongside their existing Ingress. Both objects exist at the same time.
- The ALB provisioned by the Gateway is a separate load balancer from the NLB/CLB used by ingress-nginx. DNS is not changed yet — Story 1.5 owns that. In week 1, the ALB is reachable via its auto-generated AWS DNS name for smoke testing.

**Entry criteria for parallel-run**

- [ ] Gateway API CRDs installed on cluster
- [ ] AWS Load Balancer Controller running in `kube-system`
- [ ] `team-gateway` in `platform-tools` is `Ready`
- [ ] At least one test HTTPRoute has been verified through the ALB

---

## Phase 2 — Per-app cutover sequence

Repeat this sequence for each app independently: **3.1 Versus → 3.3 Proshop → 3.5 Weather**

### Step 1 · Observe
Read the app's existing Ingress. Record:
- All hostnames (`spec.rules[].host`)
- All path rules and path types
- All backend service names and ports
- All ingress-nginx annotations and decide: translate, drop, or block

### Step 2 · Design
Draft the HTTPRoute following `docs/httproute-conventions.md`. Confirm hostname is identical to the Ingress host. Get annotation mapping decisions signed off.

### Step 3 · Ship
Open a PR into the app team's feature branch (and `main`) that:
1. Adds the HTTPRoute manifest
2. Leaves the existing Ingress untouched
3. Updates the cutover ledger (`docs/cutover-ledger.md`) row for this app

### Step 4 · Verify
After the PR merges and deploys:
- Confirm `HTTPRoute` status shows `Accepted` and `ResolvedRefs`
- Smoke test via the ALB DNS name: `curl -H "Host: <hostname>" http://<alb-dns>/`
- Confirm all paths and backends respond correctly

### Step 5 · Confirm cutover
Once verified, the app team removes their Ingress object (separate PR or same PR — their call). Update the cutover ledger row to `confirmed`.

---

## Rollback

### During parallel-run (before Ingress removed)

Rollback is instant and zero-risk:

1. Delete the HTTPRoute: `kubectl delete httproute <name> -n <namespace>`
2. ingress-nginx resumes sole ownership of that app's traffic
3. No DNS change, no downtime

The Ingress object was never touched, so there is nothing to restore.

### After Ingress removed

If an app team has already deleted their Ingress:

1. Re-apply the original Ingress manifest from git history
2. Ingress-nginx picks it up within seconds
3. Delete the HTTPRoute

This is why the Ingress manifests must be kept in git and not deleted from the repo until the decommission phase is complete.

### Controller-level rollback

If the AWS Load Balancer Controller itself needs to be removed:

```bash
helm uninstall aws-load-balancer-controller -n kube-system
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
kubectl delete -f gateway/gateway.yaml
```

ingress-nginx is unaffected — it has its own controller and does not depend on the ALB controller.

---

## Phase 3 — Decommission ingress-nginx

**Entry criteria — all of the following must be true:**

- [ ] 3.1 Versus cutover confirmed (Ingress deleted, HTTPRoute serving)
- [ ] 3.3 Proshop cutover confirmed
- [ ] 3.5 Weather cutover confirmed
- [ ] Cutover ledger shows all three rows as `confirmed`
- [ ] No other Ingress objects exist in the cluster (`kubectl get ingress -A` returns empty)

**Decommission sequence**

1. Remove the `Deploy ingress-nginx controller` step from `deploy-platform-tools.yaml`
2. Delete the ingress-nginx namespace: `kubectl delete namespace ingress-nginx` (via a workflow step or a cleanup job — not from a laptop)
3. Remove `ingress-nginx/deploy.yaml` from the repo (or keep it archived — do not re-apply it)
4. Update this doc: set Status to `complete`

**Do not decommission early.** If even one app is still on ingress-nginx and the controller is removed, that app loses all traffic with no fast path to recovery.

---

## Timeline

| Milestone | Target |
|---|---|
| Parallel-run live (Gateway + ingress-nginx both running) | Story 1.3 merge |
| 3.1 Versus cutover PR merged | Story 1.3 delivery |
| 3.3 Proshop cutover PR merged | Story 1.3 delivery |
| 3.5 Weather cutover PR merged | Story 1.3 delivery |
| ingress-nginx decommissioned | After all three confirmed |
| TLS + DNS cutover | Story 1.5 |
