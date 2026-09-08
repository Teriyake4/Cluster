# Longhorn

### Access Web Dashboard
Port forward port 80, longhorn-frontend service.
```bash
kubectl port-forward svc/longhorn-frontend 8000:80 -n longhorn-system
```
Access on <localhost:8000>

### Force Volume Deletion
If there is trouble deleting a volume, strip finalizers and/or force persistent volume deletion.

Strip Finalizers:
```bash
kubectl patch volumes.longhorn.io <pv_name> -n longhorn-system -p '{"metadata":{"finalizers":null}}' --type=merge
```

Force Deletion:
```bash
kubectl delete pv <pv_name> -n longhorn-system --grace-period=0 --force
```
