````md
# k8s-rancher

Run Ansible connectivity check first.  
Make sure the SSH private key exists at `~/.ssh/k8s.pem` and has correct permissions.

```bash
chmod 400 ~/.ssh/k8s.pem
````

Verify Ansible can reach all nodes:

```bash
ansible -i inventory/hosts.ini all -m ping \
  -u ubuntu \
  --private-key ~/.ssh/k8s.pem
```

If the ping succeeds, run the main playbook:

```bash
ansible-playbook -i inventory/hosts.ini site.yml \
  -u ubuntu \
  --private-key ~/.ssh/k8s.pem \
  -b
```

***

Disable IPIP and enable VXLAN in Calico (VXLAN-only dataplane):

```bash
kubectl patch ippool default-ipv4-ippool --type=merge -p '{
  "spec": {
    "ipipMode": "Never",
    "vxlanMode": "Always"
  }
}'
```

Remove BGP completely by disabling the node-to-node mesh:

```bash
kubectl apply -f - <<'EOF'
apiVersion: crd.projectcalico.org/v1
kind: BGPConfiguration
metadata:
  name: default
spec:
  nodeToNodeMeshEnabled: false
EOF
```

Restart Calico to apply changes:

```bash
kubectl -n kube-system rollout restart ds/calico-node
```

Verify Calico nodes initialize and become ready:

```bash
kubectl -n kube-system get pods -l k8s-app=calico-node
```

All `calico-node` pods should show:

```text
1/1 Running
```