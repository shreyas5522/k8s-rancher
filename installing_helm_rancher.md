Correct ✅ — you’re absolutely right.  
**Rancher ALWAYS requires cert-manager CRDs**, even if you run Rancher on **HTTP** and **disable ingress/TLS**.  
That’s why Helm failed with:

    no matches for kind "Issuer" in version "cert-manager.io/v1"
    ensure CRDs are installed first

Below is the **complete, correct, from‑scratch Helm-based installation**, including **cert-manager**, written as a **clean runbook** you can follow line by line.

***

````md
# Rancher Installation (Helm, HTTP, NodePort)

This installs Rancher on Kubernetes using Helm.
- HTTP only (no TLS termination)
- NodePort exposure
- cert-manager installed (required dependency)

---

## Step 1: Verify cluster health

```bash
kubectl get nodes
kubectl -n kube-system get pods
````

All nodes must be `Ready`.
All `calico-node` pods must be `1/1 Running`.

***

## Step 2: Install Helm (if not installed)

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

***

## Step 3: Install cert-manager (REQUIRED)

Rancher requires cert-manager CRDs even when using HTTP.

### Add cert-manager Helm repo

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

### Install cert-manager CRDs

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.crds.yaml
```

### Install cert-manager via Helm

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.14.4
```

### Verify cert-manager

```bash
kubectl -n cert-manager get pods
```

All pods must be `Running`:

*   cert-manager
*   cert-manager-webhook
*   cert-manager-cainjector

***

## Step 4: Add Rancher Helm repo

```bash
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update
helm search repo rancher-latest/rancher
```

***

## Step 5: Create Rancher namespace

```bash
kubectl create namespace cattle-system || true
```

***

## Step 6: Install Rancher (HTTP, NodePort)

```bash
helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname=3.150.231.167 \
  --set replicas=1 \
  --set ingress.enabled=false \
  --set service.type=NodePort \
  --set service.nodePort=30080
```

What this does:

*   Installs Rancher server
*   Disables ingress
*   Exposes Rancher via NodePort 30080
*   Uses cert-manager internally (no TLS termination)

***

## Step 7: Watch Rancher start

```bash
kubectl -n cattle-system get pods -w
```

Wait until:

    rancher-xxxxx   1/1   Running

Check service:

```bash
kubectl -n cattle-system get svc rancher
```

Expected:

    NodePort: 30080/TCP

***

## Step 8: Access Rancher UI

Open in browser:

    http://3.150.231.167:30080

Make sure the EC2 Security Group allows:

*   TCP 30080 from your IP (or 0.0.0.0/0 for testing)

***

## Step 9 (Optional): Use port 8080 instead of 30080

Kubernetes NodePort cannot directly bind to 8080.
Use iptables on the node with public IP 3.150.231.167.

```bash
sudo iptables -t nat -A PREROUTING -p tcp --dport 8080 -j REDIRECT --to-port 30080
sudo iptables -t nat -A OUTPUT -p tcp --dport 8080 -j REDIRECT --to-port 30080
```

Now access Rancher at:

    http://3.150.231.167:8080

***

## Step 10: Get Rancher bootstrap password

```bash
kubectl -n cattle-system exec \
  "$(kubectl -n cattle-system get pods -l app=rancher -o jsonpath='{.items[0].metadata.name}')" \
  -- cat /var/lib/rancher/management-state/bootstrap-secret
```

***

## Step 11: Login to Rancher

URL:

    http://3.150.231.167:30080
    # or
    http://3.150.231.167:8080

Login:

*   Username: admin
*   Password: (bootstrap secret)

Set a new password when prompted.

***

## Cleanup (if needed)

```bash
helm uninstall rancher -n cattle-system
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cattle-system cert-manager
```

***

## Notes

*   cert-manager is mandatory for Rancher
*   HTTP mode is supported but NOT secure
*   This setup is ideal for labs / PoC
*   For production, use HTTPS + Ingress

***

## URLs Summary

*   Rancher UI (NodePort):
    <http://3.150.231.167:30080>

*   Rancher UI (mapped):
    <http://3.150.231.167:8080>

```

---

### ✅ Why this will work now

- cert-manager CRDs installed ✅
- cert-manager pods running ✅
- Rancher Helm chart dependencies satisfied ✅
- No ingress/TLS conflicts ✅
- Calico already healthy ✅

---

If you want next:
- HTTPS with cert-manager
- Rancher behind Ingress
- HA Rancher (3 replicas)
- Persist iptables rules
- Import downstream clusters

Just tell me what to do next 👍
```
