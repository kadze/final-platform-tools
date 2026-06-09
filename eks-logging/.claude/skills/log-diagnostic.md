# Log Diagnostic Skill

Investigate log anomalies in the EFK stack. Given a service name and time range, fetch logs, identify patterns, and propose a root-cause hypothesis.

## Inputs

The user will provide:
- **service** — Kubernetes service/deployment name (e.g. `payments-api`, `auth-service`)
- **time range** — start and end time (e.g. `last 30 minutes`, `2026-06-09T14:00 to 2026-06-09T14:30`)
- **namespace** (optional, defaults to `logging`)

## Autonomy boundary — READ-ONLY

This skill is intentionally read-only. It **will**:
- Query Elasticsearch for logs
- Run `kubectl logs` and `kubectl describe`
- Run `kubectl get events`
- Run `kubectl top pods` (if metrics-server is available)

It **will not**:
- Delete, restart, or patch any resource
- Run `kubectl delete`, `kubectl rollout restart`, or any mutating command
- Modify any configuration

**Why read-only:** Automated remediation (deleting pods, restarting deployments) carries risk of data loss and service disruption. A human operator must confirm the hypothesis before acting. The skill's job is to surface evidence, not fix the problem.

## Steps

### 1 — Fetch logs from Elasticsearch

Query the `kubernetes-logs-*` index for the target service in the given time range.

```bash
# Replace TIME_FROM, TIME_TO, SERVICE_NAME with actual values
curl -s -u elastic:${ELASTIC_PASSWORD} \
  "http://elasticsearch.logging.svc.cluster.local:9200/kubernetes-logs-*/_search" \
  -H 'Content-Type: application/json' \
  -d '{
    "query": {
      "bool": {
        "must": [
          { "match": { "kubernetes.labels.app": "SERVICE_NAME" } },
          { "range": { "@timestamp": { "gte": "TIME_FROM", "lte": "TIME_TO" } } }
        ]
      }
    },
    "sort": [{ "@timestamp": { "order": "asc" } }],
    "size": 200
  }' | jq '.hits.hits[]._source | {time: ."@timestamp", level: .level, msg: .log}'
```

If Elasticsearch is unreachable, fall back to `kubectl logs` (step 2).

### 2 — Fetch live logs via kubectl (fallback or complement)

```bash
# Last 30 minutes of logs for a deployment
kubectl logs -n NAMESPACE deployment/SERVICE_NAME --since=30m --tail=500

# If the pod is crash-looping, get the previous container's logs
kubectl logs -n NAMESPACE deployment/SERVICE_NAME --previous --tail=200

# Check pod events (OOMKill, BackOff, pull errors)
kubectl describe pod -n NAMESPACE -l app=SERVICE_NAME | grep -A 20 "Events:"

# Check node-level events
kubectl get events -n NAMESPACE --sort-by='.lastTimestamp' | grep SERVICE_NAME
```

### 3 — Check pod health

```bash
kubectl get pods -n NAMESPACE -l app=SERVICE_NAME -o wide
kubectl top pods -n NAMESPACE -l app=SERVICE_NAME
```

### 4 — Identify patterns

Look for these specific signals in the output:

| Signal | Likely cause |
|---|---|
| `OOMKilled` in events | Memory limit too low, or memory leak |
| `CrashLoopBackOff` | Process exits non-zero — check last log lines for the error |
| `Back-off restarting failed container` | Same as above, Kubernetes throttling restarts |
| Repeated `ERROR` / `FATAL` lines with same message | Bad config, missing env var, downstream dependency down |
| HTTP 5xx spike with no restart | Bad deploy, upstream dependency degraded |
| `connection refused` or `dial tcp` errors | Service dependency unreachable — check network policy or target pod health |
| No logs at all in the time range | Fluentd not running on that node, or pod was never scheduled |

### 5 — Verify Fluentd is collecting from that node

If logs are missing from Elasticsearch but the pod is running:

```bash
# Check Fluentd is running on the same node as the pod
kubectl get pods -n logging -l app=fluentd -o wide
kubectl logs -n logging daemonset/fluentd --tail=50 | grep -i error
```

### 6 — Output format

After gathering evidence, summarise findings in this structure:

```
## Log Diagnostic — SERVICE_NAME — TIME_RANGE

### Pod status
<output of kubectl get pods>

### Key log patterns
<3-5 most significant log lines or patterns, with timestamps>

### Events
<any Kubernetes events in the window>

### Hypothesis
<one paragraph: what likely caused the anomaly, based on the evidence>

### Recommended next steps (human action required)
<bullet list of actions an operator should take to confirm and fix>
```

## Demo scenarios

### Scenario 1 — CrashLoopBackOff (bad env var / OOMKill)

Signs to look for:
- `kubectl get pods` shows `CrashLoopBackOff` or `OOMKilled`
- `kubectl logs --previous` shows the last error before exit
- Events show `Back-off restarting failed container`

Hypothesis template: _"Pod SERVICE_NAME is crash-looping due to [missing env var X / OOM at Y MB]. Last exit was [timestamp]. Recommend [adding the env var to the secret / raising memory limit to Z]."_

### Scenario 2 — Error-rate spike (bad config deploy)

Signs to look for:
- Elasticsearch shows a spike in `ERROR` log lines starting at a specific timestamp
- That timestamp correlates with a recent deploy (`kubectl rollout history`)
- HTTP 500 responses in the logs

```bash
kubectl rollout history deployment/SERVICE_NAME -n NAMESPACE
```

Hypothesis template: _"Error rate increased sharply at [timestamp], coinciding with rollout revision [N]. Log pattern [X] suggests [config key Y is invalid / downstream Z is returning errors]. Recommend rolling back to revision [N-1] if confirmed."_
