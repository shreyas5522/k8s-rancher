# k8s-rancher

bash ```
ansible -i inventory/hosts.ini all -m ping \
  -u ubuntu \
  --private-key ~/.ssh/k8s.pem
```
ansible-playbook -i inventory/hosts.ini site.yml   -u ubuntu   --private-key ~/.ssh/k8s.pem   -b
