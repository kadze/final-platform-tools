# HTTPRoute Conventions

How to attach your app to the shared Gateway API traffic plane.  
Applies to: **3.1 Versus · 3.3 Proshop · 3.5 Weather**

---

## Gateway reference

There is one shared Gateway for the team, managed by the platform:

| Field | Value |
|---|---|
| Name | `team-gateway` |
| Namespace | `platform-tools` |
| Listener | `http` — port 80, HTTP only |
| Allowed routes | All namespaces |

Your HTTPRoute attaches to it via `parentRefs`. You do not create or modify the Gateway yourself.

`allowedRoutes.namespaces.from: All` is a deliberate choice over `ReferenceGrant` — all app namespaces belong to the same team, so the extra cross-namespace grant mechanism adds operational overhead with no meaningful security benefit at this stage.

---

## Hostname contract

Use the **same hostname your Ingress was using today**. Do not change it.

Story 1.5 (external-dns + cert-manager) will wire Route53 and TLS on top of these same hostnames. If you change the hostname now, the 1.5 cutover breaks.

```yaml
spec:
  hostnames:
    - "versus.dev.internal"   # whatever your Ingress host field said
```

If your Ingress had no `host` field (catch-all), omit `hostnames` from the HTTPRoute entirely — it will match all traffic on the listener.

---

## parentRefs — how to attach to the Gateway

Every HTTPRoute must declare this exact `parentRefs` block:

```yaml
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: team-gateway
      namespace: platform-tools
```

The `namespace: platform-tools` cross-namespace reference is what connects your route (in your app's namespace) to the shared Gateway. The Gateway's `allowedRoutes.namespaces.from: All` permits this.

---

## Route and backend shape

Map each Ingress rule to an HTTPRoute rule. The structure is a direct translation:

| Ingress field | HTTPRoute equivalent |
|---|---|
| `rules[].http.paths[].path` | `rules[].matches[].path.value` |
| `pathType: Prefix` | `path.type: PathPrefix` |
| `pathType: Exact` | `path.type: Exact` |
| `backend.service.name` | `backendRefs[].name` |
| `backend.service.port.number` | `backendRefs[].port` |

```yaml
rules:
  - matches:
      - path:
          type: PathPrefix
          value: /api
    backendRefs:
      - name: my-service
        port: 8080
```

Multiple paths from a single Ingress rule become multiple `matches` entries under the same HTTPRoute rule, or separate rules — either is valid.

---

## Annotation mapping

ingress-nginx annotations do not carry over to HTTPRoute. Each one needs a deliberate decision:

| ingress-nginx annotation | HTTPRoute equivalent | Action |
|---|---|---|
| `nginx.ingress.kubernetes.io/rewrite-target` | `filters[].urlRewrite.path` | Translate to URLRewrite filter |
| `nginx.ingress.kubernetes.io/ssl-redirect` | n/a | **Drop** — HTTP-only in week 1; Story 1.5 handles TLS |
| `nginx.ingress.kubernetes.io/force-ssl-redirect` | n/a | **Drop** — same as above |
| `nginx.ingress.kubernetes.io/proxy-body-size` | n/a | No direct equivalent; configure at the app level |
| `nginx.ingress.kubernetes.io/cors-*` | n/a | Handle in app or use a policy attachment (future) |
| `kubernetes.io/ingress.class: nginx` | Replaced by `parentRefs` | **Drop** — parentRefs is the new attachment mechanism |

If your app has an annotation not listed here, open a platform ticket before migrating.

---

## IPv6 note

You do not need to change anything in your app or Service for IPv6. The ALB uses `ip` target type, which means it routes directly to pod IPs. Since pods on this cluster get IPv6 addresses, the ALB reaches them over IPv6. Your Service type (`ClusterIP`, `NodePort`, etc.) is irrelevant to this — the ALB bypasses kube-proxy entirely.

**Where `ip` target type comes from:** it is set as the controller-wide default in the LBC Helm values (`defaultTargetType: ip`). You will not see it in your HTTPRoute manifest — there is no annotation or CRD field to set. The controller applies it automatically to every target group it creates. Do not add a `TargetGroupConfiguration` to override this unless you have a specific reason.

The one thing to verify: your Service's `selector` must match your pod labels correctly. The ALB controller registers pod IPs into the target group directly.

---

## What NOT to do

- **No TLS annotations** — do not add `cert-manager.io/cluster-issuer`, `nginx.ingress.kubernetes.io/ssl-*`, or any certificate reference. That is Story 1.5's job. Adding them now will not work and will block the 1.5 rollout.
- **Do not delete your Ingress yet** — both traffic planes run in parallel during the migration window. Your Ingress stays until the platform team confirms all apps have cut over and ingress-nginx is decommissioned.
- **Do not create your own Gateway or GatewayClass** — use `team-gateway` in `platform-tools`. Rogue Gateways provision extra ALBs and break the subnet quota.

---

## Full worked example

### Before — classic Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: versus
  namespace: versus
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
    - host: versus.dev.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: versus-svc
                port:
                  number: 80
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: versus-api-svc
                port:
                  number: 8080
```

### After — HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: versus
  namespace: versus
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: team-gateway
      namespace: platform-tools
  hostnames:
    - "versus.dev.internal"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: versus-api-svc
          port: 8080
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: versus-svc
          port: 80
```

Note: the `rewrite-target: /` annotation is dropped here because both backends already serve at `/`. If your rewrite is load-bearing, add a `URLRewrite` filter to the relevant rule.

---

## Questions

Slack the platform team or open a PR against this doc. Do not guess on annotation mappings — get confirmation before shipping.
