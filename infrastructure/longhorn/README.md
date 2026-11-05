# Longhorn

### Access Web Dashboard
The Longhorn UI is exposed at `longhorn.elmatcha.lan` or `longhorn.elmatcha.ianchao.com` through the Traefik ingress, protected by HTTP Basic Authentication.

Set up the credentials per environment (`.env` is gitignored; a
`.env.example` template is committed under `overlays/{dev,prod}/`):
```bash
cd infrastructure/longhorn/overlays/prod
cp .env.example .env
```
Replace the `users` value with the output of
`htpasswd -nbB <username> '<password>'` (only the hash is stored, never the
plaintext password).

Then apply the overlay – the `secretGenerator` in the kustomization creates the
`longhorn-basic-auth` Secret from `.env`:
```bash
kubectl apply -k infrastructure/longhorn/overlays/prod
```

Access <http://longhorn.elmatcha.lan> and log in with the user defined in
`.env`. To change the password, edit `.env` and re-apply.

The manifests live in `base/longhorn-ingress.yaml` (Ingress) and
`base/longhorn-middleware.yaml` (BasicAuth Middleware).

Alternatively, port forward port 80, longhorn-frontend service
(bypasses the ingress authentication):
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
