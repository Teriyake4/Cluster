# Cluster

K3s cluster running on Alpine Linux with heterogeneous nodes configured for high availability.

## Additional Setup

Edit `/etc/rancher/k3s/config.yaml`

### Control Plane:

```yaml
node-ip: "LAN_IP,TAILSCALE_IP"
advertise-address: "LAN_IP"
flannel-iface: eth0
tls-san:
  - LAN_IP
  - TAILSCALE_IP
disable-agent: true # Ignore line or set false for Control Plane/Worker nodes
```

### Worker:

```yaml
node-ip: "LAN_IP,TAILSCALE_IP"
flannel-iface: eth0
```

## Building and Deploying

### Building

```sh
# Build
docker build --platform linux/amd64 -t APP_NAME:latest .
# Tag
docker tag APP_NAME:latest REGISTRY_IP:30500/APP_NAME
# Push
docker push REGISTRY_IP:30500/APP_NAME:latest
```

One line
```sh
docker build --platform linux.amd64 -t REGISTRY_IP:30500/APP_NAME:latest --push .
```

### Deploying

Create `deployment.yaml` and `kustimization.yaml` for `dev` and `prod`.

Deploying locally
```sh
kubectl apply -k APP_NAME/overlays/dev
```

Deploying production
```sh
kubectl apply -k APP_NAME/overlays/prod
```

Applying secrets
```sh
kubectl create secret generic SECRET_NAME --from-env-file=.env
```
