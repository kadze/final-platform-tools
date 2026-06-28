# Autonomy Decision — diagnose-logs skill

## What the skill may do without human confirmation

| Action | Allowed | Reason |
|---|---|---|
| `kubectl port-forward svc/elasticsearch` | Yes | Opens a local tunnel, no cluster state change |
| `kubectl get pods / describe pod / logs` | Yes | Read-only Kubernetes API |
| `curl ES /_search /_count` (GET) | Yes | Read-only Elasticsearch query |
| `kubectl logs --previous` | Yes | Read-only, retrieves terminated container output |

## What the skill must stop and ask a human before doing

| Action | Why it requires human confirmation |
|---|---|
| `kubectl delete / scale / rollout restart` | Modifies running workloads — could worsen an incident |
| `curl ES -X PUT/POST/DELETE` (writes) | Could corrupt index mappings or delete data |
| `kubectl exec` into a container | Grants shell access; hard to audit; outside read-only scope |
| Any `aws` CLI call | Out of scope; skill is Kubernetes / ES read layer only |

## Why read-only

The skill is designed for triage, not remediation. An on-call engineer who has
just been paged at 3 AM benefits most from a fast, safe summary that tells them
*what* is broken and *why* — not from an autonomous agent that might restart pods
or reindex data and make the situation harder to reason about.

The least-privilege path: the skill authenticates to Elasticsearch as the
`elastic` superuser only because that credential is already in the
`elasticsearch-credentials` K8s secret used by the stack. A production hardening
step would be to create a read-only ES role (`diagnose_reader`) and a dedicated
secret — so even if the skill's context is exfiltrated, an attacker cannot write
to or delete indices.

## Autonomy boundary in the skill prompt

The boundary is enforced in `.claude/skills/diagnose-logs.md` under the
"Autonomy boundary" section, which lists explicit allow/deny lists and instructs
the model to stop and ask before taking any write action.
