# Authentik Forward Auth for Prometheus & AlertManager

This guide sets up Authentik-based authentication for Prometheus and AlertManager using nginx-ingress forward auth.

## Overview

- **Prometheus** will be protected at `${PROMETHEUS_HOST}`
- **AlertManager** will be protected at `${ALERTMANAGER_HOST}`
- Both use Authentik's embedded outpost for forward authentication
- Users must be in an Authentik group to access

## Prerequisites

✅ **Already completed in your setup:**
- Authentik deployed in `auth` namespace
- nginx-ingress with `allowSnippetAnnotations: true`
- `annotations-risk-level: "Critical"` in nginx config

## Files Modified

```
k8s/stacks/monitor/
├── authentik-external-service.yaml      (NEW)
├── ingress.yaml                          (UPDATED)
└── kustomization.yaml                    (UPDATED)
```

## Setup Steps

### 1. Create Authentik Applications & Providers

In Authentik UI, create two **Proxy Providers**:

#### For Prometheus:
- **Name:** Prometheus
- **Authorization flow:** default-provider-authorization-implicit-consent
- **External host:** `https://${PROMETHEUS_HOST}` (with trailing slash)
- **Internal host:** `http://prometheus-operated.monitor.svc.cluster.local:9090`
- **Allowed redirect URIs:** `https://${PROMETHEUS_HOST}/outpost.goauthentik.io/callback`

#### For AlertManager:
- **Name:** AlertManager
- **Authorization flow:** default-provider-authorization-implicit-consent
- **External host:** `https://${ALERTMANAGER_HOST}` (with trailing slash)
- **Internal host:** `http://alertmanager-operated.monitor.svc.cluster.local:9093`
- **Allowed redirect URIs:** `https://${ALERTMANAGER_HOST}/outpost.goauthentik.io/callback`

### 2. Create Applications

Create two **Applications** in Authentik:

#### For Prometheus:
- **Name:** Prometheus
- **Slug:** prometheus
- **Provider:** Prometheus (the proxy provider you created above)
- **Group access:** Set which Authentik groups can access

#### For AlertManager:
- **Name:** AlertManager
- **Slug:** alertmanager
- **Provider:** AlertManager (the proxy provider you created above)
- **Group access:** Set which Authentik groups can access

### 3. Verify Users & Groups

Ensure your Authentik user is assigned to the groups you configured in the applications:
```bash
# Example group names
- homelab-admins
- homelab-ops
```

### 4. Deploy Changes

Commit and push your changes:
```bash
cd /path/to/homelab-infra
git add k8s/stacks/monitor/
git commit -m "Add Authentik forward auth to Prometheus and AlertManager"
git push origin main
```

ArgoCD will automatically sync within 3 minutes.

### 5. Verify Deployment

```bash
# Check ExternalName service exists
kubectl get svc -n monitor authentik-server
# Output should show: ExternalName   authentik-server.auth.svc.cluster.local

# Check ingress has auth annotations
kubectl get ingress -n monitor prometheus -o yaml | grep "auth-url"

# Check AlertManager too
kubectl get ingress -n monitor alertmanager -o yaml | grep "auth-url"

# Monitor outpost logs
kubectl logs -n auth -l app.kubernetes.io/component=server -f | grep outpost
```

## Testing

1. Navigate to `https://${PROMETHEUS_HOST}` in your browser
2. You should be redirected to Authentik login
3. Log in with your Authentik credentials
4. You should be redirected back and see Prometheus
5. Repeat for AlertManager at `https://${ALERTMANAGER_HOST}`

## Troubleshooting

### 401 Unauthorized (no redirect to login)
- **Issue:** Auth annotations not applied or ingress not updated
- **Fix:** Run `kubectl get ingress -n monitor prometheus -o yaml` and verify `auth-url` annotation exists
- **Check:** Authentik provider external URL ends with `/` (trailing slash is critical!)

### 503 Service Unavailable
- **Issue:** ExternalName service not found
- **Fix:** Run `kubectl get svc -n monitor authentik-server` — should return ExternalName service
- **Check:** Authentik pods are running: `kubectl get pods -n auth`

### Infinite redirect loop
- **Issue:** `auth-signin` URL is incorrect or using wrong domain
- **Fix:** Verify `${PROMETHEUS_HOST}` and `${ALERTMANAGER_HOST}` are set in cluster-vars ConfigMap
- **Command:** `kubectl get cm -n argocd cluster-vars -o yaml | grep HOST`

### "Risky annotation" webhook error
- **Issue:** nginx-ingress doesn't allow snippet annotations
- **Fix:** This should already be configured in your helm-values.yaml:
  ```yaml
  allowSnippetAnnotations: true
  annotations-risk-level: "Critical"
  ```
- **Verify:** Restart nginx-ingress pods after confirming helm-values are set

## How It Works

1. User accesses `https://prometheus.example.com`
2. nginx-ingress forwards request to Authentik outpost at `/outpost.goauthentik.io/auth/nginx`
3. Outpost checks if user is authenticated
4. If not: redirects to Authentik login (`/outpost.goauthentik.io/start`)
5. User logs in via Authentik
6. Authentik redirects back to original URL with session cookie
7. nginx-ingress adds auth headers (username, groups, email, etc.) to request
8. Request is allowed to reach Prometheus/AlertManager backend

## Auth Headers Available

The following headers are passed to your applications (useful for logging):

```
X-authentik-username    # Username in Authentik
X-authentik-groups      # Comma-separated group names
X-authentik-email       # User email
X-authentik-name        # User display name
X-authentik-uid         # Authentik user ID
X-authentik-entitlements  # Additional entitlements
```

## Next Steps

- Monitor auth requests: `kubectl logs -n auth -l app.kubernetes.io/component=server -f`
- Check Authentik provider status in Authentik UI
- Review audit logs in Authentik for login attempts
- Consider adding group-based restrictions for security

## References

- [Authentik Proxy Provider Documentation](https://goauthentik.io/docs/providers/proxy)
- [nginx-ingress Forward Auth](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#external-authentication)
