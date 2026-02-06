# k8s-rancher

bash ```
ansible -i inventory/hosts.ini all -m ping \
  -u ubuntu \
  --private-key ~/.ssh/k8s.pem
```
bash ```
ansible-playbook -i inventory/hosts.ini site.yml   -u ubuntu   --private-key ~/.ssh/k8s.pem   -b
```
bash ```
sudo kubectl patch felixconfiguration default --type=merge -p '{
  "spec": {
    "bpfEnabled": false
  }
}
```


kubectl patch ippool default-ipv4-ippool --type=merge -p '{
  "spec": {
    "ipipMode": "Never",
    "vxlanMode": "Always"
  }
}'