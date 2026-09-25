# Kube-VIP

### Node Setup
Add the virtual IP address to each of the nodes' `config.yaml` and to the `.env` file.
```
KUBE_VIP=$KUBE_VIP
```
```yaml
tls-san:
  - "$KUBE_VIP"
```

Get the kube-vip daemonset manifest for the control planes, this can be done outside of the cluster.
The `<KUBE_VERSION>` can be referenced here: <https://github.com/kube-vip/kube-vip/releases>
Set `<KUBE_VIP>` as the main virtual IP address for the control planes.
```bash
docker run --rm ghcr.io/kube-vip/kube-vip:<KUBE_VERSION> manifest daemonset \
    --interface eth0 \
    --address <KUBE_VIP> \
    --inCluster \
    --taint \
    --controlplane \
    --arp \
    --leaderElection > daemonset-cp.yaml
```

Get the kube-vip daemonset manifest for the worker nodes.
```bash
docker run --rm ghcr.io/kube-vip/kube-vip:<KUBE_VERSION> manifest daemonset \
    --interface eth0 \
    --inCluster \
    --taint \
    --services \
    --arp > daemonset-services.yaml
```

Disable default servicelb on control planes at `/etc/rancher/k3s/config.yaml`
```yaml
disable:
  - servicelb
```
