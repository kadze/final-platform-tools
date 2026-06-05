# Cutover Ledger

Tracks the Ingress → HTTPRoute migration status for each app.  
Updated as PRs are opened, merged, and confirmed.

See `docs/migration-plan.md` for the per-app cutover sequence.  
See `docs/httproute-conventions.md` for the HTTPRoute authoring contract.

---

## Status key

| Status | Meaning |
|---|---|
| `pending` | Cutover PR not yet opened |
| `pr-open` | PR submitted into app team's branch, awaiting review/merge |
| `merged` | PR merged, HTTPRoute deployed, smoke test in progress |
| `confirmed` | Traffic verified through ALB, Ingress deleted by app team |

---

## Apps in scope

| App | Story | Branch | Cutover PR | HTTPRoute status | Ingress removed | Notes |
|---|---|---|---|---|---|---|
| Versus | 3.1 | `feature/3.1-versus` | — | `pending` | No | |
| Proshop | 3.3 | `feature/3.3-proshop` | — | `pending` | No | |
| Weather backend | 3.5 | `feature/3.5-weather` | — | `pending` | No | |

---

## Apps out of scope

| App | Story | Reason |
|---|---|---|
| Versus on EC2 | 3.2 | Does not run on the cluster — no Ingress to migrate |
| Serverless | 3.4 | Does not run on the cluster — no Ingress to migrate |

---

## Decommission gate

ingress-nginx will be removed **only when all three rows above show `confirmed` and `Ingress removed: Yes`**.

Current state: **0 / 3 confirmed** — ingress-nginx remains active.
