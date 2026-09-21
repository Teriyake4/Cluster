# Longhorn

### Access Web Dashboard
Port forward port 80, longhorn-frontend service.
```bash
kubectl port-forward svc/longhorn-frontend 8000:80 -n longhorn-system
```
Access on <localhost:8000>

### Additional Setup
If there are additional drives, first mount the drive:
```bash
doas mount -a
```
Then add propagation using the command. The path may be `/mnt/storage`
```bash
doas mount --make-rshared <path>
```
To make it persistent accross restarts add the line to `/etc/init.d/mount-rshared` file.
```bash
if mountpoint -q /mnt/storage; then
    mount --make-shared <path>
fi
```
To verify mount propagation, run:
```bash
findmnt -o TARGET,SOURCE,PROPAGATION <path>
```

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
