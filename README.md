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

### Building (on development machine)

```sh
docker buildx build --platform linux/amd64 -t REGISTRY_IP:30500/APP_NAME:latest --push .
```

Applying secrets (on development machine)
```sh
kubectl create secret generic SECRET_NAME --from-env-file=.env
```

### Deploying (on cluster)

Add `deployment.yaml` to `deployments` dir.
Sample `deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: APP_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: APP_NAME
  template:
    metadata:
      labels:
        app: APP_NAME
    spec:
      containers:
      - name: APP_NAME
        image: registry.local/APP_NAME:latest
        imagePullPolicy: Always
```
Deploy Image
```sh
kubectl apply -f deployment.yaml
```
