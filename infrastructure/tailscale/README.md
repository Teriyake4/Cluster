# The Complete Network Flows (Updated Architecture)

## Network Components and IP Addresses

| Component | IP address |
|---|---|
| Home LAN | `192.168.1.0/24` |
| Pi-hole kube-vip | `192.168.1.2` |
| Traefik kube-vip | `192.168.1.50` |
| Minecraft kube-vip | `192.168.1.60` |

*All addresses are examples and should be replaced with the actual values from your cluster.*

The three service addresses are all kube-vip Virtual IPs, each provided by a Kubernetes `LoadBalancer` Service pinned via the `kube-vip.io/loadbalancerIPs` annotation. In particular, the Pi-hole LAN DNS address (`192.168.1.2`) is not a static IP on a physical device. No other device on the LAN may actually own that address: a physical Pi-hole (or any DHCP lease) at `192.168.1.2` would cause an ARP conflict and a second, shadowing DNS database.

## Flow A: You Are at Home (Local LAN — Web Application)

1. You type `https://app.cluster.lan` on your home PC (Tailscale OFF).
2. Your PC asks Pi-hole for the IP address using its LAN-facing DNS endpoint (`192.168.1.2`).
3. Pi-hole looks up its local DNS record and replies: `192.168.1.50`.
4. Your PC sends HTTPS traffic directly to `192.168.1.50` over the local network.
5. kube-vip advertises the LoadBalancer IP, and Kubernetes Service networking forwards the traffic to Traefik.
6. Traefik terminates HTTPS, matches the hostname `app.cluster.lan`, and routes the request to the backend application's Kubernetes Service.
7. The backend application responds through Traefik and the existing Kubernetes/LAN network path.

**The Tailscale Connector is running but completely uninvolved in this request.**

## Flow B: You Are Away (Remote via Tailscale — Web Application)

### Phase 1: DNS Resolution

1. You type `https://app.cluster.lan` on your laptop at a coffee shop (Tailscale ON).
2. Your laptop performs a DNS lookup.
3. Tailscale's DNS configuration recognizes the Split-DNS rule for `cluster.lan`.
4. The rule directs the DNS query to Pi-hole's kube-vip address (`192.168.1.2`).
5. Because this address is advertised through the Tailscale Connector, the DNS query travels through the encrypted Tailscale connection to the Connector Pod.
6. The Connector forwards the DNS query to Pi-hole's kube-vip address.
7. Pi-hole looks up `app.cluster.lan` in its existing DNS database and returns `192.168.1.50`.
8. Your laptop receives exactly the same DNS answer that a local home PC would receive.

**Pi-hole remains the single source of truth. MagicDNS does not resolve application hostnames or maintain separate records for them.**

### Phase 2: HTTPS Traffic

1. Your laptop initiates an HTTPS connection to `192.168.1.50:443`.
2. Tailscale recognizes that the route `192.168.1.50/32` is advertised by the Kubernetes Connector.
3. Tailscale access policies determine whether the laptop is authorized to access that destination and port.
4. If authorized, your laptop sends the TCP traffic through the encrypted Tailscale tunnel.
5. The Tailscale Connector Pod receives the traffic and forwards it toward the kube-vip address `192.168.1.50`.
6. kube-vip and Kubernetes Service networking deliver the traffic to Traefik.
7. Traefik terminates HTTPS, matches `app.cluster.lan`, and routes the request to the correct backend application.
8. The application responds through the reverse network path to the laptop.

**Pi-hole is involved only in DNS resolution, not the subsequent application data transfer. The Connector handles network routing, while Traefik remains responsible for HTTPS and application routing.**

## Flow C: You Are at Home (Local LAN — Minecraft Server)

1. You open Minecraft Java Edition on your home PC (Tailscale OFF).
2. You enter `minecraft.cluster.lan` as the server address.
3. Your PC asks Pi-hole for the IP.
4. Pi-hole returns `192.168.1.60`.
5. Minecraft connects to `192.168.1.60:25565` over the local network.
6. kube-vip advertises the Minecraft LoadBalancer IP, and Kubernetes Service networking forwards the TCP connection to the Minecraft Pod.
7. The Minecraft server responds to the client.

**Neither Tailscale nor Traefik is involved. Minecraft is accessed directly through its Kubernetes LoadBalancer Service.**

## Flow D: You Are Away (Remote via Tailscale — Minecraft Server)

### Phase 1: DNS Resolution

1. You open Minecraft on your laptop with Tailscale enabled.
2. You enter `minecraft.cluster.lan` as the server address.
3. Tailscale's Split-DNS configuration directs the lookup to Pi-hole's kube-vip address (`192.168.1.2`).
4. The DNS query travels through the Tailscale Connector to Pi-hole.
5. Pi-hole returns `192.168.1.60`, the Minecraft LoadBalancer IP.

### Phase 2: Minecraft Traffic

1. Minecraft initiates a TCP connection to `192.168.1.60:25565`.
2. Tailscale identifies the route `192.168.1.60/32`, advertised by the Kubernetes Connector.
3. Tailscale access policies verify whether the client is permitted to connect to TCP port 25565.
4. If authorized, the connection travels through the encrypted Tailscale tunnel to the Connector Pod.
5. The Connector forwards the traffic toward the Minecraft LoadBalancer IP.
6. kube-vip and Kubernetes Service networking deliver the connection to the Minecraft Pod.
7. The Minecraft server communicates with the laptop over the established connection.

**Traefik is completely uninvolved. The Connector supports non-HTTP TCP and UDP traffic, so game servers do not require an HTTP reverse proxy.**

---

## Infrastructure Responsibilities

### Pi-hole (Single DNS Source of Truth)

Pi-hole runs as a Pod inside the k3s cluster.

It maintains all internal DNS records:

```text
app.cluster.lan       → 192.168.1.50   # Traefik kube-vip VIP
grafana.cluster.lan   → 192.168.1.50   # Traefik kube-vip VIP
argocd.cluster.lan    → 192.168.1.50   # Traefik kube-vip VIP
minecraft.cluster.lan → 192.168.1.60   # Minecraft kube-vip VIP
```

Local devices reach Pi-hole through its kube-vip address (`192.168.1.2`).

Remote Tailscale devices reach the same Pi-hole instance through the same kube-vip address using the Connector.

The address is provided by a `LoadBalancer` Service pinned via the `kube-vip.io/loadbalancerIPs` annotation, exactly like the Traefik and Minecraft VIPs, so it is stable by design rather than a static IP on a physical device.

**There is only one DNS database and one set of application hostname records.**

### Tailscale Connector (k3s Subnet Router)

The Connector is a Kubernetes Custom Resource managed by the Tailscale Operator.

The Operator creates and maintains the corresponding Tailscale-connected workload inside k3s.

Its primary responsibility is to provide remote Tailscale devices with routes to selected private Kubernetes and LAN addresses.

A single Connector workload would advertise:

```text
192.168.1.2/32   → Pi-hole DNS
192.168.1.50/32  → Traefik ingress
192.168.1.60/32  → Minecraft server
```

A single Connector can advertise all three routes and still enforce different access per user and per service: Tailscale access controls distinguish destination IP and port even when all routes come from one subnet router. See Remote Access Control and Security.

The Connector does not resolve DNS names, terminate HTTPS, or make application-level routing decisions.

It forwards authorized IP traffic to the appropriate destination.

Its own Tailscale IP is managed by Tailscale and does not need to appear in Pi-hole's application DNS records.

### Tailscale DNS / Split DNS

The Tailscale Admin Console centrally defines:

```text
Domain:     cluster.lan
Nameserver: 192.168.1.2
```

`cluster.lan` is a placeholder for the cluster's actual apex domain (the existing Ingresses use `elmatcha.lan`).

When a Tailscale-connected client resolves a hostname under `cluster.lan`, the query is directed to Pi-hole through the Connector.

MagicDNS may remain enabled to resolve Tailscale device hostnames, but Pi-hole remains authoritative for your internal application records.

No separate remote DNS database or hardcoded Tailscale application IPs are required.

### kube-vip (Kubernetes LoadBalancer Addresses)

kube-vip provides stable LAN-facing LoadBalancer addresses for Kubernetes Services.

In this architecture:

- `192.168.1.2` is used by Pi-hole.
- `192.168.1.50` is used by Traefik.
- `192.168.1.60` is used by Minecraft.

Both local and remote clients connect to these same destination addresses.

Local traffic reaches the addresses through the LAN.

Remote traffic reaches them through the Tailscale Connector, assuming the Connector Pod can successfully route to these VIPs.

### Traefik (HTTPS Ingress Controller)

Traefik handles HTTP/HTTPS application traffic.

It receives connections through the LoadBalancer VIP `192.168.1.50`.

It terminates HTTPS, evaluates hostname-based routes, applies configured middleware, and forwards requests to backend Kubernetes Services.

Traefik does not need special per-client Tailscale configuration.

Non-HTTP applications such as Minecraft can bypass Traefik entirely.

---

## Remote Access Control and Security

The Tailscale Connector advertises destination routes, but advertising a route does not automatically authorize every tailnet client to use it.

**Tailscale access control works per destination and per port.** Both the classic ACL syntax and the newer grants syntax restrict access by destination IP/CIDR and port, not merely by destination node. A policy can distinguish `192.168.1.2:53` (Pi-hole DNS), `192.168.1.50:443` (Traefik), and `192.168.1.60:25565` (Minecraft) even when a single Connector advertises all three routes. Classic ACLs express this as `<host>:<ports>` entries in the `dst` field; grants separate the destination from protocol/port restrictions in the `ip` field and can additionally use `via` to constrain which subnet routers may carry the traffic.

A single Connector can therefore advertise all three routes while a least-privilege policy enforces per-service access:

| Destination | Allowed port | Authorized clients |
|---|---|---|
| Pi-hole `192.168.1.2` | 53 (TCP and UDP) | Homelab users |
| Traefik `192.168.1.50` | 443 | Homelab users |
| Minecraft `192.168.1.60` | 25565 | Homelab users and authorized players |

All other destination/port combinations should be denied. Broad pre-existing allow-all policies must be removed or restricted for these limits to take effect.

**Route injection is separate from access.** A rule permitting `192.168.1.60:25565` does not by itself inject the `192.168.1.60/32` route into clients. Routes are injected when the Connector's advertised routes are approved in the Admin Console, independently of the access rules. Every client that needs a service therefore receives the route, and the access rules decide which of those clients may actually use it, and to which port.

**Players and DNS.** If players are granted only `192.168.1.60:25565`, they cannot resolve `minecraft.cluster.lan` through Pi-hole and must enter the raw VIP in Minecraft. If hostname-based access is desired for players, grant them `192.168.1.2:53` as well — they still reach Pi-hole only on port 53, so the DNS exposure is limited to the service itself.

**Other security considerations:**

- An authorized but compromised client can still reach the services its policy permits.
- Tailscale network permissions do not replace application authentication.
- Multiple HTTPS applications sharing `192.168.1.50:443` share the same network-level access boundary.
- The Connector masquerades (source-NATs) routed traffic, so Traefik and Pi-hole see the Connector as the source rather than the individual remote client. Per-client Pi-hole blocklists and source-IP-based authentication therefore do not work for remote clients; application-layer authentication is the only reliable per-user control.
- The kube-vip addresses live on the LAN itself: anything already on the LAN (or anything that pivots onto it) can reach the services directly regardless of the tailnet. Tailscale protects only the remote path.
- Kubernetes NetworkPolicies and application authentication provide additional protection against lateral movement.

---

## Client Configuration

For most clients, setup consists of installing Tailscale and signing into an authorized tailnet account.

Tailscale centrally distributes the DNS configuration, approved routes, and access policies.

Windows, macOS, iOS, and Android generally accept subnet routes automatically. Linux clients typically require:

```bash
sudo tailscale set --accept-routes=true
```

If `cluster.lan` uses certificates issued by a private certificate authority, client devices must also trust that CA.

No manual Pi-hole DNS configuration or application-specific Tailscale IP mapping is required on each client.

---

## Important Architectural Notes

**Kubernetes reachability:** The Connector Pod must be able to reach all three kube-vip addresses. In particular, routing from a Pod to a LAN VIP depends on the k3s CNI, kube-vip mode, and Kubernetes Service networking. This must be tested before deployment — from inside the Connector Pod, and including from a Pod scheduled on the node that currently holds a given VIP (the hairpin case):

```bash
dig @192.168.1.2 <app>.cluster.lan   # Pi-hole DNS
nc 192.168.1.50 443                  # Traefik
nc 192.168.1.60 25565                # Minecraft
```

**Split-horizon behavior:** A laptop on the home LAN with Tailscale enabled may still use Tailscale for DNS or application traffic. The advertised `/32` routes can take precedence over the broader local LAN route. Physical location alone does not determine which path is selected.

**High availability:** A single Connector replica is a potential single point of failure for all traffic routed through the tailnet. That includes Tailscale-on devices on the home LAN: Split DNS still points at the Connector, and the more-specific `/32` tailnet routes take precedence over the local LAN route, so when the Connector is down, `cluster.lan` resolution and service traffic are lost even though Pi-hole and the VIPs are right there on the LAN. Tailscale-off devices on the home LAN are unaffected.

The standard fix is redundant subnet routers: Tailscale supports multiple subnet routers advertising the same prefixes for failover. By default (regional routing off), Tailscale treats them as active-passive — all traffic for a route goes to a single primary router (oldest addition to the tailnet first), and when the primary goes offline it is removed from consideration and traffic fails over to another healthy router advertising the same prefix. Deploy the Connector as two workloads with the same tag (for example, two Connector Custom Resources), each advertising the same three `/32` routes, and approve the routes once in the Admin Console. A grants `via` entry naming the shared tag can pin traffic to that router pair while still permitting failover. Do not enable `--accept-routes` on the routers in this setup: a standby would accept its own advertised routes from the primary and take an inefficient routing path — `--advertise-routes` alone is the intended configuration.

**Failure behavior:** If the Connector fails, all traffic routed through the tailnet is unavailable; local access on Tailscale-off devices continues. If Pi-hole fails, `cluster.lan` resolution fails for both local and remote clients. If a kube-vip VIP stops being served, the corresponding service is unavailable for both local and remote clients.

**Rollback:** To roll back remote access, delete the Connector Custom Resource(s) and remove the Split-DNS domain from the Admin Console. Pi-hole, kube-vip, and Traefik are untouched, so local access is unaffected.

**Static IP addressing:** Stable kube-vip addresses are used as application and DNS destinations. Tailscale-assigned IPs do not need to be hardcoded into Pi-hole records.

**Network isolation:** The Connector advertises individual service addresses rather than the entire LAN or Kubernetes network. This reduces the exposed routing surface, but Kubernetes networking and Tailscale access policies must still be secured.

**Minecraft edition:** The example uses Minecraft Java Edition on TCP 25565. Bedrock Edition typically uses UDP 19132 and would require the corresponding Service and access policy.

---

## Final Architecture Summary

**At home:**

```text
Client → Pi-hole DNS
Client → kube-vip → Traefik / Minecraft → Backend
```

**Away from home:**

```text
Client → Tailscale → Connector → Pi-hole DNS

Client → Tailscale → Connector → kube-vip
       → Traefik / Minecraft → Backend
```

**The central principle:**

Pi-hole determines **where** the service lives.

Tailscale determines **who** can connect remotely.

The Connector determines **how** remote traffic reaches the private destination.

kube-vip and Kubernetes Service networking deliver traffic to the correct workload.

Traefik handles HTTP/HTTPS application routing, while non-HTTP services such as Minecraft can be accessed directly.

The result is one DNS source of truth, consistent local and remote hostnames, minimal client configuration, and centrally managed remote access controls.
