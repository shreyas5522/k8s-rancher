
## **🚀 COMPLETE RANCHER INSTALLATION GUIDE**

### **Prerequisites Check**
```bash
# Check cluster status
kubectl get nodes
kubectl cluster-info
```

### **PHASE 1: PREPARATION**

**Step 1.1: Label Control-Plane Node**
```bash
kubectl label node ip-10-0-6-214 ingress-ready=true
```

**Step 1.2: Add Helm Repositories**
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update
```

### **PHASE 2: CERT-MANAGER INSTALLATION**

**Step 2.1: Install cert-manager**
```bash
kubectl create namespace cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.14.5 \
  --set installCRDs=true
```

**Step 2.2: Wait for cert-manager**
```bash
sleep 30
kubectl -n cert-manager wait --for=condition=Ready pods --all --timeout=300s
kubectl -n cert-manager get pods
```

### **PHASE 3: NGINX INGRESS INSTALLATION**

**Step 3.1: Create NGINX values file**
```bash
cat <<EOF > nginx-values.yaml
controller:
  hostNetwork: true
  kind: Deployment
  service:
    type: ClusterIP
    enabled: false
  hostPort:
    enabled: true
  nodeSelector:
    ingress-ready: "true"
  tolerations:
  - key: "node-role.kubernetes.io/control-plane"
    effect: "NoSchedule"
    operator: "Exists"
EOF
```

**Step 3.2: Install NGINX**
```bash
kubectl create namespace ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  -f nginx-values.yaml
```

**Step 3.3: Verify NGINX**
```bash
kubectl -n ingress-nginx get pods -o wide
kubectl -n ingress-nginx get deployment
```

### **PHASE 4: NETWORK CONFIGURATION**

**Step 4.1: Fix rp_filter on Control-Plane**
```bash
# Check current value
cat /proc/sys/net/ipv4/conf/all/rp_filter

# Fix it
sudo sysctl -w net.ipv4.conf.all.rp_filter=2
echo "net.ipv4.conf.all.rp_filter=2" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Verify
cat /proc/sys/net/ipv4/conf/all/rp_filter
```

### **PHASE 5: COREDNS CONFIGURATION**

**Step 5.1: Get Control-Plane IP**
```bash
CONTROL_PLANE_IP=$(kubectl get node ip-10-0-6-214 -o jsonpath='{.status.addresses[0].address}')
echo "Control Plane IP: $CONTROL_PLANE_IP"
```

**Step 5.2: Update CoreDNS**
```bash
# Backup current config
kubectl -n kube-system get configmap coredns -o yaml > coredns-backup.yaml

# Update CoreDNS with the host entry
kubectl -n kube-system get configmap coredns -o yaml | \
  sed "/forward \. \/etc\/resolv.conf {/i\        hosts {\n          $CONTROL_PLANE_IP rancher.shreyash.cloud\n          fallthrough\n        }" | \
  kubectl apply -f -

# Restart CoreDNS
kubectl -n kube-system rollout restart deployment coredns
kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=120s
```

### **PHASE 6: RANCHER INSTALLATION**

**Step 6.1: Install Rancher with CORRECT ingress class**
```bash
kubectl create namespace cattle-system
helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --create-namespace \
  --set hostname=rancher.shreyash.cloud \
  --set bootstrapPassword=admin \
  --set replicas=1 \
  --set ingress.ingressClassName=nginx \
  --set ingress.tls.source=rancher
```

**Step 6.2: Wait for Rancher**
```bash
sleep 30
kubectl -n cattle-system wait --for=condition=Ready pods -l app=rancher --timeout=300s
kubectl -n cattle-system get pods
```

### **PHASE 7: LET'S ENCRYPT CERTIFICATE SETUP**

**Step 7.1: Create ClusterIssuer (REPLACE EMAIL!)**
```bash
# Replace admin@shreyash.cloud with YOUR email
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@shreyash.cloud  # ⚠️ CHANGE THIS TO YOUR REAL EMAIL!
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
```

**Step 7.2: Create Certificate**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: rancher-tls
  namespace: cattle-system
spec:
  secretName: rancher-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  commonName: rancher.shreyash.cloud
  dnsNames:
  - rancher.shreyash.cloud
EOF
```

**Step 7.3: Monitor Certificate**
```bash
# Watch certificate status
kubectl -n cattle-system get certificate -w

# In another terminal, watch challenges
kubectl -n cattle-system get challenge -w
```

### **PHASE 8: NGINX CERTIFICATE CONFIGURATION**

**Step 8.1: Configure NGINX to use Let's Encrypt certificate**
```bash
kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type=merge \
  -p '{"data":{"default-ssl-certificate":"cattle-system/rancher-tls"}}'
```

**Step 8.2: Restart NGINX**
```bash
kubectl -n ingress-nginx rollout restart deployment ingress-nginx-controller
kubectl -n ingress-nginx wait --for=condition=Ready pods --all --timeout=180s
```
