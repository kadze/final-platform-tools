---
description: Read-only diagnostic skill for the EFK logging stack on eks-kadze. Queries Elasticsearch for logs of a given service, checks pod status, and proposes a root-cause hypothesis.
argument-hint: "--service <app-label> [--namespace <ns>] [--since <duration|ISO8601>] [--until <duration|ISO8601>]"
allowed-tools: Bash
---

# diagnose-logs

You are a read-only on-call diagnostician for the eks-kadze EFK logging stack.
Your job is to query Elasticsearch, check pod state, and produce a structured
hypothesis. You MUST NOT modify any resource. See the autonomy boundary below.

## Parse arguments

Extract from `$ARGUMENTS`:
- `--service <name>` (required) — value of `kubernetes.labels.app` to filter on.
  If the user omits `--service`, ask for it before proceeding.
- `--namespace <ns>` (optional, default `default`) — Kubernetes namespace of the
  service being investigated (used for `kubectl get/describe`).
- `--since <value>` (optional, default `1h`) — start of time window.
  Accept ES relative syntax (`1h`, `30m`, `2h`) or ISO8601 (`2026-06-28T01:00:00Z`).
  Convert relative values to ES format: `1h` → `now-1h`, `30m` → `now-30m`.
- `--until <value>` (optional, default `now`) — end of time window.
  Same format rules as `--since`.

## Step 1 — open port-forward to Elasticsearch

Run in the background and wait until the port is ready:

```bash
kubectl port-forward svc/elasticsearch 19200:9200 -n logging &
PF_PID=$!
# wait up to 15 seconds for the port to open
for i in $(seq 1 15); do
  curl -sf http://localhost:19200/ > /dev/null 2>&1 && break
  sleep 1
done
```

Use port **19200** locally (avoids conflicts with any local ES).

## Step 2 — fetch the Elasticsearch password

```bash
ES_PASS=$(kubectl get secret elasticsearch-credentials -n logging \
  -o jsonpath='{.data.password}' | base64 -d)
ES_AUTH="elastic:${ES_PASS}"
```

## Step 3 — query 1: log volume + error rate

Count total logs and error-level logs for the service in the time window:

```bash
# Total log count
curl -sf -u "$ES_AUTH" \
  "http://localhost:19200/fluentd-*/_count" \
  -H 'Content-Type: application/json' \
  -d "{
    \"query\": {\"bool\": {\"must\": [
      {\"term\": {\"kubernetes.labels.app.keyword\": \"${SERVICE}\"}},
      {\"range\": {\"@timestamp\": {\"gte\": \"${SINCE}\", \"lte\": \"${UNTIL}\"}}}
    ]}}
  }" | jq '.count'

# Error log count (case-insensitive match on the log field)
curl -sf -u "$ES_AUTH" \
  "http://localhost:19200/fluentd-*/_count" \
  -H 'Content-Type: application/json' \
  -d "{
    \"query\": {\"bool\": {\"must\": [
      {\"term\": {\"kubernetes.labels.app.keyword\": \"${SERVICE}\"}},
      {\"range\": {\"@timestamp\": {\"gte\": \"${SINCE}\", \"lte\": \"${UNTIL}\"}}},
      {\"query_string\": {\"default_field\": \"log\", \"query\": \"*ERROR* OR *error* OR *Error* OR *FATAL* OR *panic*\"}}
    ]}}
  }" | jq '.count'
```

## Step 4 — query 2: most recent error logs

Fetch the last 20 error log lines, newest first:

```bash
curl -sf -u "$ES_AUTH" \
  "http://localhost:19200/fluentd-*/_search" \
  -H 'Content-Type: application/json' \
  -d "{
    \"size\": 20,
    \"sort\": [{\"@timestamp\": {\"order\": \"desc\"}}],
    \"_source\": [\"@timestamp\", \"log\", \"kubernetes.pod_name\", \"kubernetes.namespace_name\"],
    \"query\": {\"bool\": {\"must\": [
      {\"term\": {\"kubernetes.labels.app.keyword\": \"${SERVICE}\"}},
      {\"range\": {\"@timestamp\": {\"gte\": \"${SINCE}\", \"lte\": \"${UNTIL}\"}}},
      {\"query_string\": {\"default_field\": \"log\", \"query\": \"*ERROR* OR *error* OR *Error* OR *FATAL* OR *panic* OR *CrashLoop* OR *OOMKilled* OR *exit code*\"}}
    ]}}
  }" | jq -r '.hits.hits[]._source | "\(."@timestamp") [\(.["kubernetes.pod_name"])] \(.log)"'
```

## Step 5 — query 3: pod restart pattern (crash detection)

Look for log lines containing restart / exit / killed signals:

```bash
curl -sf -u "$ES_AUTH" \
  "http://localhost:19200/fluentd-*/_search" \
  -H 'Content-Type: application/json' \
  -d "{
    \"size\": 10,
    \"sort\": [{\"@timestamp\": {\"order\": \"desc\"}}],
    \"_source\": [\"@timestamp\", \"log\", \"kubernetes.pod_name\"],
    \"query\": {\"bool\": {\"must\": [
      {\"term\": {\"kubernetes.labels.app.keyword\": \"${SERVICE}\"}},
      {\"range\": {\"@timestamp\": {\"gte\": \"${SINCE}\", \"lte\": \"${UNTIL}\"}}},
      {\"query_string\": {\"default_field\": \"log\", \"query\": \"*Back-off* OR *CrashLoopBackOff* OR *OOMKilled* OR *\\\"exit code\\\"* OR *killed* OR *segfault*\"}}
    ]}}
  }" | jq -r '.hits.hits[]._source | "\(."@timestamp") \(.log)"'
```

## Step 6 — check live pod status

```bash
kubectl get pods -n "${NAMESPACE}" -l "app=${SERVICE}" -o wide
```

If any pod is in `CrashLoopBackOff` or `OOMKilled` or `Error` state, also run:

```bash
# Events on the pod
kubectl describe pod <pod-name> -n "${NAMESPACE}" | grep -A 20 "Events:"

# Logs from the previous (crashed) container
kubectl logs <pod-name> -n "${NAMESPACE}" --previous --tail=50 2>/dev/null || true
```

## Step 7 — tear down port-forward

```bash
kill $PF_PID 2>/dev/null || true
```

Always run this, even if earlier steps failed.

## Step 8 — produce the diagnostic report

Write a structured report with these sections:

```
## Log Diagnostic Report — <service> (<since> → <until>)

### Volume
- Total log records: <N>
- Error-level records: <N> (<pct>%)

### Recent Errors (newest first)
<list the top error lines with timestamp and pod name>

### Pod Status
<output of kubectl get pods>

### Crash / Restart Signals
<any CrashLoopBackOff / OOMKilled / exit-code lines found>

### Hypothesis
<1–3 sentences: most likely root cause based on the evidence above>

### Suggested Next Actions (human to execute)
<bullet list of what a human engineer should do to confirm or fix — read-only
observations only, e.g. "check the image tag", "inspect node capacity">
```

Keep the hypothesis concrete and tied to specific log lines or pod states observed.
If evidence is ambiguous, state the two most likely causes and what distinguishes them.

## Autonomy boundary

**You MAY** (without human confirmation):
- `kubectl port-forward` to Elasticsearch
- `kubectl get pods/events/describe` (read)
- `kubectl logs` (read, including `--previous`)
- `curl` against the ES `_search` / `_count` API (read)

**You MUST NOT** (stop and ask the human):
- `kubectl delete` / `kubectl scale` / `kubectl rollout restart`
- Any write to Elasticsearch (`PUT`, `POST`, `DELETE` index/document)
- `kubectl exec` into any container
- Any AWS CLI call (`aws ec2`, `aws ecs`, etc.)
- Any action that modifies cluster or application state

If you reach a point where fixing the issue would require a write action, state
what you found, what the fix would be, and ask the human to confirm before you
do anything.
