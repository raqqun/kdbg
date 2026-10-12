# iptables

`iptables` shows and changes the Linux firewall rules: which packets are
allowed, dropped, or rewritten. In Kubernetes, kube-proxy in its iptables mode
uses these rules to make Services work. A connection to a Service's ClusterIP
is rewritten by these rules to go to one of the Service's pods. Some CNIs
(Calico, for example) also implement NetworkPolicies with iptables rules, and
service meshes like Istio use them to redirect a pod's traffic to the sidecar.

kdbg has `iptables` 1.8 with the **nf_tables backend** only. Read
[Legacy and nf_tables](#legacy-and-nf_tables) before you start: if the node
uses the other backend, kdbg's `iptables` shows nothing useful.

## When to use it in a cluster

- A Service doesn't forward to its pods, or forwards to the wrong ones.
- A NodePort or LoadBalancer Service doesn't answer on a node.
- Checking how kube-proxy spreads traffic across endpoints.
- Checking what a service mesh does with a pod's traffic.
- Looking for a firewall rule that drops traffic on a node.

## Privileges

`iptables` needs `NET_ADMIN`, and you need to be in the right network: for
kube-proxy's rules, the node's. Use:

```sh
kubectl debug node/<node> -it --image=ghcr.io/raqqun/kdbg --profile=sysadmin -- bash
```

For a pod's own rules (like a service mesh's), attach to the pod with
`--profile=netadmin`.

## Which mode does kube-proxy use?

kube-proxy reports its mode on the node, on port 10249:

```sh
curl -s localhost:10249/proxyMode
```

- `iptables`: this page.
- `nftables`: see [nft](nft.md).
- `ipvs`: kube-proxy uses the kernel's IPVS load balancer, and only uses
  iptables for some helper rules. kdbg doesn't include `ipvsadm`, so look at
  IPVS from the kube-proxy pod.

If nothing answers, kube-proxy may not be running at all. Some CNIs replace it,
like Cilium with its kube-proxy replacement, which uses eBPF instead of
iptables. Then you won't find Service rules here. Use the CNI's own tools, like
`kubectl -n kube-system exec ds/cilium -- cilium-dbg service list`.

## Common commands

```sh
iptables-save                              # Every rule in every table, in a form you can grep
iptables-save -t nat                       # Only the nat table, where Service rules live
iptables-save | grep 'my-namespace/my-svc' # Every rule for one Service
iptables -t nat -L KUBE-SERVICES -n        # List one chain
iptables -t nat -L KUBE-SVC-XXXXXXXXXXXXXXXX -n -v   # With packet and byte counters
iptables -L -n -v --line-numbers           # filter table, with counters and rule numbers
iptables -S KUBE-FORWARD                   # One chain, in iptables-save format
ip6tables-save                             # The same for IPv6
iptables -V                                # Version and backend
```

| Option | What it does |
| --- | --- |
| `-t TABLE` | Table: `filter` (default), `nat`, `mangle`, `raw` |
| `-L [CHAIN]` | List rules |
| `-S [CHAIN]` | List rules as commands |
| `-n` | Numbers, no name lookups. Always use it. |
| `-v` | Show counters and interfaces |
| `-x` | Exact counter values |
| `--line-numbers` | Number the rules |
| `-Z [CHAIN]` | Reset counters |

## How kube-proxy's rules fit together

kube-proxy names its chains `KUBE-*`, and adds a comment to every rule with
the Service it belongs to. A packet to a ClusterIP goes through these chains,
in the `nat` table:

```text
PREROUTING / OUTPUT
  └─ KUBE-SERVICES               one rule per Service port: matches ClusterIP + port
       └─ KUBE-SVC-<hash>         one per Service port: picks an endpoint at random
            ├─ KUBE-SEP-<hash>    one per endpoint: DNAT to pod IP + port
            ├─ KUBE-SEP-<hash>
            └─ KUBE-SEP-<hash>
```

For a Service `my-svc` in `my-namespace` with three pods:

```text
-A KUBE-SERVICES -d 10.96.142.17/32 -p tcp -m comment --comment "my-namespace/my-svc:http cluster IP" -m tcp --dport 80 -j KUBE-SVC-ULMVA6XWZ3BQ2ZQO
-A KUBE-SVC-ULMVA6XWZ3BQ2ZQO -m comment --comment "my-namespace/my-svc:http -> 10.244.1.12:8080" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-4XWZ2BX7Z3NQ6YPB
-A KUBE-SVC-ULMVA6XWZ3BQ2ZQO -m comment --comment "my-namespace/my-svc:http -> 10.244.2.31:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-RLNPJD3A4FDDRTYF
-A KUBE-SVC-ULMVA6XWZ3BQ2ZQO -m comment --comment "my-namespace/my-svc:http -> 10.244.3.8:8080" -j KUBE-SEP-2EOKAYC5BHDFGQXN
-A KUBE-SEP-4XWZ2BX7Z3NQ6YPB -p tcp -m comment --comment "my-namespace/my-svc:http" -m tcp -j DNAT --to-destination 10.244.1.12:8080
```

The probabilities look uneven, but they're applied one after the other: a
third of connections go to the first endpoint, half of the rest to the second,
and everything left to the third. Each gets a third.

Other chains you'll see:

| Chain | Table | What it's for |
| --- | --- | --- |
| `KUBE-NODEPORTS` | nat | NodePort Services: matches the node port |
| `KUBE-EXT-<hash>` | nat | Traffic from outside the cluster (NodePort, LoadBalancer, external IPs) |
| `KUBE-SVL-<hash>` | nat | Only the local endpoints, for `externalTrafficPolicy: Local` or `internalTrafficPolicy: Local` |
| `KUBE-MARK-MASQ`, `KUBE-POSTROUTING` | nat | Mark packets that need their source rewritten, and rewrite it (masquerade) |
| `KUBE-SERVICES`, `KUBE-EXTERNAL-SERVICES` | filter | `REJECT` rules for Services with no endpoints |
| `KUBE-FORWARD` | filter | Allows forwarded traffic that kube-proxy handles |
| `KUBE-PROXY-FIREWALL` | filter | `loadBalancerSourceRanges` |

## Recipes

### Are a Service's rules there, and do they point to the right pods?

```sh
iptables-save -t nat | grep 'my-namespace/my-svc'
```

You should see a `KUBE-SERVICES` rule for each port of the Service, and one
`KUBE-SEP` with a `DNAT` per ready pod. Compare the IPs with the
EndpointSlices:

```sh
kubectl get endpointslices -n my-namespace -l kubernetes.io/service-name=my-svc -o wide
```

If the rules are missing or out of date on one node only, kube-proxy on that
node isn't keeping up. Check its logs:
`kubectl -n kube-system logs <kube-proxy-pod-on-that-node>`.

### A Service with no endpoints

```sh
iptables-save -t filter | grep 'has no endpoints'
```

```text
-A KUBE-SERVICES -d 10.96.142.17/32 -p tcp -m comment --comment "my-namespace/my-svc:http has no endpoints" -m tcp --dport 80 -j REJECT --reject-with icmp-port-unreachable
```

Connections to it are refused right away. Clients see `Connection refused`.
The Service has no ready pods: check its selector and the pods' readiness.

### Does traffic hit the rules?

Counters show how many packets each rule matched:

```sh
watch -n 1 'iptables -t nat -L KUBE-SVC-ULMVA6XWZ3BQ2ZQO -n -v -x'
```

Send some traffic to the Service and watch the counters go up. Rules whose
counters don't move aren't being matched. That's where to look.

### Trace a packet through every rule

On the nf_tables backend, you can ask the kernel to report every rule a packet
passes. Add a temporary rule that marks the packets to follow, watch, then
remove it:

```sh
iptables -t raw -I PREROUTING -p tcp -d 10.96.142.17 --dport 80 -j TRACE
xtables-monitor --trace
# send a request from a pod, watch the output, then Ctrl+C
iptables -t raw -D PREROUTING -p tcp -d 10.96.142.17 --dport 80 -j TRACE
```

Each packet is printed once per table, followed by the rules it matched in
that table:

```text
PACKET: 2 d3e2b520 IN=cali8a1b2c3d4e5 SRC=10.244.1.5 DST=10.96.142.17 LEN=60 TTL=64 DF SPORT=50486 DPORT=80 SYN
 TRACE: 2 d3e2b520 raw:PREROUTING:rule:0x2:CONTINUE  iptables -t raw -A PREROUTING -d 10.96.142.17/32 -p tcp -m tcp --dport 80 -j TRACE
 TRACE: 2 d3e2b520 raw:PREROUTING:policy:ACCEPT
PACKET: 2 d3e2b520 IN=cali8a1b2c3d4e5 SRC=10.244.1.5 DST=10.96.142.17 LEN=60 TTL=64 DF SPORT=50486 DPORT=80 SYN
 TRACE: 2 d3e2b520 nat:PREROUTING:rule:0x1:JUMP:KUBE-SERVICES  ...
 TRACE: 2 d3e2b520 nat:KUBE-SERVICES:rule:0x5:JUMP:KUBE-SVC-ULMVA6XWZ3BQ2ZQO  ...
```

The last line for a packet in each table shows where it ended: `ACCEPT`,
`DROP`, a `DNAT`, or the chain's default policy.

For traffic started on the node itself, use the `OUTPUT` chain instead of
`PREROUTING`. Tracing generates a lot of output: match the packets as narrowly
as you can, and always remove the rule afterwards.

### What does the service mesh do with this pod's traffic?

Attach to the pod with `--profile=netadmin`, then:

```sh
iptables-save -t nat
```

With Istio's sidecar, for example, you'll see `ISTIO_INBOUND`, `ISTIO_OUTPUT`
and `ISTIO_REDIRECT` chains redirecting traffic to the sidecar's ports (15001
for outgoing, 15006 for incoming). Ports and addresses excluded from the mesh
show up as `RETURN` rules.

## Legacy and nf_tables

There are two kinds of iptables in Linux. They keep separate rule sets and
don't see each other's rules:

- **legacy**: the original kernel interface.
- **nf_tables** (`iptables-nft`): the same commands, stored as nftables rules.
  Most current distributions use this.

kdbg's `iptables` uses nf_tables:

```sh
iptables -V
```

```text
iptables v1.8.13 (nf_tables)
```

If the node (or kube-proxy) uses legacy, kdbg shows almost no rules, or this
warning:

```text
# Warning: iptables-legacy tables present, use iptables-legacy to see them
```

Use the node's own `iptables`, through the node's filesystem at `/host`:

```sh
chroot /host iptables-save
```

Or ask kube-proxy, whose image detects the right mode:

```sh
kubectl -n kube-system exec <kube-proxy-pod> -- iptables-save
```

## Pitfalls

- **Wrong network, wrong rules.** In a regular pod, `iptables` shows the pod's
  own rules, usually none. kube-proxy's rules are on the node.
- **Wrong backend.** See [Legacy and nf_tables](#legacy-and-nf_tables).
- **Don't change kube-proxy's rules.** kube-proxy rewrites them regularly, so
  manual changes disappear, or worse, break Services until they do. Only add
  temporary rules (like tracing) and remove them.
- **`-L` without `-n` is slow**, because it looks up a name for every address.
- **Hashes differ between clusters.** The `KUBE-SVC-...` names are hashes of
  the Service name and port. Search by the comment (`namespace/name:port`),
  not by the hash.
- **IPv6 rules are separate.** Use `ip6tables-save` for dual-stack and IPv6
  Services.

## Related

- [nft](nft.md), for kube-proxy's nftables mode, and nftables rules in general
- [conntrack](conntrack.md), for connections already set up by these rules
- [tcpdump](tcpdump.md), to see packets before and after the rules apply

## Manuals

- [iptables](https://manpages.debian.org/stable/iptables/iptables.8.en.html)
- [iptables extensions](https://manpages.debian.org/stable/iptables/iptables-extensions.8.en.html)
- [Virtual IPs and Service proxies](https://kubernetes.io/docs/reference/networking/virtual-ips/)
