---
title: Authentik Embedded Outpost Forward Authentication Guide
description: Complete implementation guide for protecting Kubernetes services with Authentik embedded outpost using nginx-ingress
---

# Adding Authentik Embedded Outpost Forward Authentication

This guide documents the complete process for protecting a Kubernetes service with Authentik's embedded outpost using nginx-ingress forward authentication.

## Prerequisites

- Authentik deployed and running with embedded outpost
- An Authentik application + proxy provider already created for your service
- User groups configured in Authentik (e.g., "homelab-admins")
- nginx-ingress controller deployed
- Service to protect running in Kubernetes

## Architecture Overview

```
User Request
    ↓
nginx-ingress (validates auth via auth-url)
    ↓
Authentik embedded outpost (/outpost.goauthentik.io/auth/nginx)
    ↓
If not authenticated:
    → Redirect to auth-signin (outpost login endpoint)
    → User logs in to Authentik
    → Redirected back with session cookie
    ↓
If authenticated + authorized:
    → outpost returns 200 with auth headers
    → nginx-ingress allows request through
    ↓
Backend Service receives request + auth headers
```

## Critical Learning: Outpost Location

**KEY INSIGHT**: The outpost endpoint must be accessible on the **same domain** as your application, not on the Authentik domain.

### Wrong Approach ❌
```yaml
nginx.ingress.kubernetes.io/auth-signin: |-
  https://auth.in.example.com/outpost.goauthentik.io/start?rd=...
```
This causes cross-domain issues and auth failures.

### Correct Approach ✅
```yaml
nginx.ingress.kubernetes.io/auth-signin: |-
  https://myapp.in.example.com/outpost.goauthentik.io/start?rd=...
```
Expose the outpost endpoint on the application's own ingress.

## Step-by-Step Implementation

### 1. Enable Snippet Annotations in nginx-ingress

Update your nginx-ingress helm values to allow risky annotations:

```yaml
# k8s/infrastructure/ingress-nginx/helm-values.yaml
controller:
  service:
    type: LoadBalancer
  config:
    ssl-redirect: "true"
    force-ssl-redirect: "true"
    use-forwarded-headers: "true"
    compute-full-forwarded-for: "true"
    annotations-risk-level: "Critical"  # CRITICAL: Allows snippet annotations
  resources:
    requests:
      cpu: 100m
      memory: 90Mi
    limits:
      cpu: 250m
      memory: 256Mi
```

**Why both settings?**
- `allowSnippetAnnotations: true` enables snippet annotations generally
- `annotations-risk-level: Critical` actually allows them (webhook still filters by risk level)

### 2. Create ExternalName Service for Cross-Namespace Access

Kubernetes Ingress cannot directly reference services in other namespaces. Use an ExternalName service as a bridge:

```yaml
# k8s/infrastructure/<service>/authentik-external-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: authentik-server
  namespace: <service-namespace>  # e.g., longhorn-system
  labels:
    app.kubernetes.io/name: authentik
    app.kubernetes.io/component: server
spec:
  type: ExternalName
  externalName: authentik-server.auth.svc.cluster.local
  ports:
    - port: 9000
      targetPort: 9000
      protocol: TCP
```

Then add to kustomization:
```yaml
# k8s/infrastructure/<service>/kustomization.yaml
resources:
  - authentik-external-service.yaml
  - ingress.yaml
  - recurring-jobs.yaml
```

### 3. Configure Service Ingress with Forward Auth

```yaml
# k8s/infrastructure/<service>/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <service>-ingress
  namespace: <service-namespace>
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    
    # Forward auth endpoint (internal DNS, not public)
    nginx.ingress.kubernetes.io/auth-url: |-
      http://authentik-server.auth.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx
    
    # Redirect to login on auth failure (same domain as app)
    nginx.ingress.kubernetes.io/auth-signin: |-
      https://${SERVICE_HOST}/outpost.goauthentik.io/start?rd=$scheme://$http_host$escaped_request_uri
    
    # Required auth response headers
    nginx.ingress.kubernetes.io/auth-response-headers: |-
      Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-entitlements,X-authentik-email,X-authentik-name,X-authentik-uid
    
    # Required for proper Authentik header handling
    nginx.ingress.kubernetes.io/auth-snippet: |
      proxy_set_header X-Forwarded-Host $http_host;

spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${SERVICE_HOST}
      secretName: ${WILDCARD_SECRET}
  rules:
    - host: ${SERVICE_HOST}
      http:
        paths:
          # Outpost endpoint (MUST be first)
          - path: /outpost.goauthentik.io/
            pathType: Prefix
            backend:
              service:
                name: authentik-server
                port:
                  number: 9000
          
          # Backend service
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <service>-frontend
                port:
                  number: <port>
```

### 4. Verify Authentik Configuration

In Authentik admin UI, for your service's Proxy Provider:

- ✅ Provider type: **Proxy Provider**
- ✅ External URL: `https://${SERVICE_HOST}/` (with trailing slash)
- ✅ Authorization flow: configured with group policies
- ✅ User groups: verify service group is assigned

## Common Issues & Solutions

### Issue: 401 Unauthorized (instead of redirect to login)

**Cause**: Auth-signin annotation not redirecting to login page

**Solution**: 
- Verify auth-signin URL uses the application's hostname, not Authentik's
- Ensure `/outpost.goauthentik.io/` path is in the ingress rules
- Check Authentik provider has correct external URL

### Issue: 503 Service Unavailable

**Cause**: Authentik backend unreachable

**Solution**:
- Verify ExternalName service exists in the application namespace
- Check ExternalName points to correct FQDN: `authentik-server.auth.svc.cluster.local`
- Verify auth namespace and service name are correct

### Issue: Admission webhook denied - "risky annotation"

**Cause**: `annotations-risk-level` not set to "Critical"

**Solution**:
- Update nginx-ingress helm values
- Set `controller.config.annotations-risk-level: "Critical"`
- Sync and restart controller pods

### Issue: Cross-domain auth issues

**Cause**: Outpost endpoint on different domain than application

**Solution**:
- Always expose outpost on the application's own domain
- Use ExternalName service + ingress path routing
- Do NOT route to auth.example.com/outpost.goauthentik.io

## Troubleshooting Checklist

```bash
# 1. Verify nginx-ingress has correct config
kubectl get cm -n ingress-nginx ingress-nginx-controller -o yaml | grep annotations-risk-level

# 2. Check ExternalName service exists
kubectl get svc -n <service-namespace> authentik-server
kubectl get svc -n <service-namespace> authentik-server -o yaml

# 3. Verify ingress paths are correct
kubectl get ingress -n <service-namespace> <service>-ingress -o yaml

# 4. Check Authentik logs for auth requests
kubectl logs -n auth -l app.kubernetes.io/component=server -f | grep outpost

# 5. Verify Authentik provider is loaded by outpost
kubectl logs -n auth -l app.kubernetes.io/component=server -f | grep "Loaded application"

# 6. Test auth endpoint directly
kubectl exec -it -n ingress-nginx <nginx-pod> -- \
  curl http://authentik-server.auth.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx
```

## Configuration Reference

### Annotation Breakdown

| Annotation | Purpose | Value |
|-----------|---------|-------|
| `auth-url` | Where nginx calls to validate auth | Internal DNS to Authentik outpost `/auth/nginx` endpoint |
| `auth-signin` | Where to redirect on auth failure | Public URL to outpost `/start` endpoint on same domain |
| `auth-response-headers` | Headers to capture from outpost | User identity headers (username, groups, email, etc.) |
| `auth-snippet` | Raw nginx config for auth | `proxy_set_header X-Forwarded-Host $http_host;` |

### ExternalName Service Pattern

Use for any cross-namespace service reference:
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: <service-name>
  namespace: <consumer-namespace>
spec:
  type: ExternalName
  externalName: <service>.<target-namespace>.svc.cluster.local
  ports:
    - port: <port>
      targetPort: <port>
```

## Files Modified

- `k8s/infrastructure/ingress-nginx/helm-values.yaml` — Add `annotations-risk-level: Critical`
- `k8s/infrastructure/<service>/authentik-external-service.yaml` — Create new ExternalName service
- `k8s/infrastructure/<service>/ingress.yaml` — Add forward-auth annotations + outpost path
- `k8s/infrastructure/<service>/kustomization.yaml` — Include external service
- `k8s/stacks/auth/ingress.yaml` — Remove outpost path (centralize on each app instead)

## Next Steps for Multiple Services

To protect another service (e.g., AlertManager, Prometheus):

1. Create `k8s/infrastructure/<service>/authentik-external-service.yaml`
2. Add forward-auth annotations to that service's ingress
3. Add `/outpost.goauthentik.io/` path to its ingress rules
4. Update its kustomization.yaml

The same pattern applies to all services.

## References

- [Authentik Forward Auth Documentation](https://goauthentik.io/)
- [nginx-ingress Forward Auth](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#external-authentication)
- [Kubernetes ExternalName Services](https://kubernetes.io/docs/concepts/services-networking/service/#externalname)
- [Cross-Namespace Service Access](https://oneuptime.com/blog/post/2026-02-09-cross-namespace-ingress-routing/view)
