# nft

`nft` is the command-line tool for nftables, the current Linux firewall. It
replaces `iptables` and stores everything (filtering, NAT, sets and maps) in
one rule set. In Kubernetes you'll meet it when:

- kube-proxy runs in **nftables mode**, available in recent Kubernetes
  versions, where Services are implemented as nftables rules.
- The node uses `iptables-nft`: rules made with `iptables` are stored as
  nftables rules too, and `nft` shows them.
- A CNI, firewall or the node's own setup uses nftables directly.

## When to use it in a cluster

- A Service doesn't forward to its pods on a node where kube-proxy runs in
  nftables mode.
- Seeing every firewall rule on a node in one place, whatever created it.
- Tracing a packet through all rules to find the one that drops it.

## Privileges

`nft` needs `NET_ADMIN`, in the node's network:

```sh
kubectl debug node/<node> -it --image=ghcr.io/raqqun/kdbg --profile=sysadmin -- bash
```

To check whether kube-proxy uses nftables mode, run
`curl -s localhost:10249/proxyMode` on the node. See
[iptables](iptables.md#which-mode-does-kube-proxy-use).

## Common commands

```sh
nft list tables                          # All tables
nft list ruleset                         # Everything. Can be long.
nft list table ip kube-proxy             # One table
nft list chain ip kube-proxy services    # One chain
nft list map ip kube-proxy service-ips   # One map
nft -a list chain ip filter FORWARD      # With rule handles (needed to delete a rule)
nft -n list ruleset                      # Numbers instead of names for ports and protocols
nft -j list ruleset                      # JSON
nft monitor                              # Print rule changes as they happen
nft monitor trace                        # Print traced packets (see below)
```

## How nftables is organised

```text
table <family> <name>
  ├─ chain <name>         rules, run in order. "Base" chains hook into the network stack.
  ├─ set <name>           a list of values (IPs, ports...) that rules can match
  └─ map <name>           values mapped to results, often "jump to this chain"
```

The family says what traffic a table sees: `ip` (IPv4), `ip6`, `inet` (both),
`arp`, `bridge`, `netdev`.

Rules created by `iptables-nft` show up as tables like `ip filter`, `ip nat` and
`ip mangle`, using compatibility expressions. `nft` marks them with a warning:

```text
# Warning: table ip nat is managed by iptables-nft, do not touch!
```

Read them with `iptables` commands instead. They're easier to read there.

## kube-proxy's nftables mode

kube-proxy puts everything in two tables, `ip kube-proxy` and
`ip6 kube-proxy`. Instead of one rule per Service, it uses maps, which stay fast
with many Services.

```sh
nft list map ip kube-proxy service-ips
```

```text
table ip kube-proxy {
    map service-ips {
        type ipv4_addr . inet_proto . inet_service : verdict
        comment "ClusterIP, ExternalIP and LoadBalancer IP traffic"
        elements = { 10.96.0.10 . udp . 53 : goto service-FY5PMXPG-kube-system/kube-dns/udp/dns,
                     10.96.142.17 . tcp . 80 : goto service-ULMVA6XW-my-namespace/my-svc/tcp/http,
                     ... }
    }
}
```

Each element maps a ClusterIP, protocol and port to the Service's chain. Chain
names include the namespace, Service name, protocol and port name, so you can
find them by name:

```sh
nft list table ip kube-proxy | grep 'my-namespace/my-svc'
```

A Service chain picks an endpoint at random:

```text
chain service-ULMVA6XW-my-namespace/my-svc/tcp/http {
    ip daddr 10.96.142.17 tcp dport 80 ip saddr != 10.244.0.0/16 jump mark-for-masquerade
    numgen random mod 3 vmap { 0 : goto endpoint-5OJB2KTY-my-namespace/my-svc/tcp/http__10.244.1.12/8080,
                               1 : goto endpoint-WAHRBT2B-my-namespace/my-svc/tcp/http__10.244.2.31/8080,
                               2 : goto endpoint-QVSJBPRR-my-namespace/my-svc/tcp/http__10.244.3.8/8080 }
}
```

and an endpoint chain rewrites the destination to the pod:

```text
chain endpoint-5OJB2KTY-my-namespace/my-svc/tcp/http__10.244.1.12/8080 {
    ip saddr 10.244.1.12 jump mark-for-masquerade
    meta l4proto tcp dnat to 10.244.1.12:8080
}
```

Other useful parts:

| Name | What it is |
| --- | --- |
| `service-nodeports` map | NodePort Services |
| `no-endpoint-services`, `no-endpoint-nodeports` maps | Services with no ready pods: their traffic is rejected |
| `cluster-ips` set | All ClusterIPs |
| `firewall-ips` map | `loadBalancerSourceRanges` |
| `external-<hash>-...` chains | Traffic from outside the cluster |
| `mark-for-masquerade`, `masquerading` chains | Rewriting the source address where needed |

## Recipes

### Is the Service there, and which pods does it point to?

```sh
nft list map ip kube-proxy service-ips | grep 10.96.142.17
nft list table ip kube-proxy | grep 'my-namespace/my-svc'
```

You should find one `endpoint-...` chain per ready pod, with the pod's IP and
port in its name. Compare with
`kubectl get endpointslices -n my-namespace -l kubernetes.io/service-name=my-svc`.

If the Service appears in `no-endpoint-services`, it has no ready pods, and
connections to it are refused.

Chain names contain slashes, so quote them when you list one:

```sh
nft list chain ip kube-proxy 'service-ULMVA6XW-my-namespace/my-svc/tcp/http'
```

### Trace a packet through every rule

nftables can report every rule a packet passes, in every table, including
`iptables-nft` ones. Create a temporary table that marks the packets to
follow:

```sh
nft add table ip kdbg-trace
nft add chain ip kdbg-trace pre '{ type filter hook prerouting priority -350; }'
nft add rule ip kdbg-trace pre ip daddr 10.96.142.17 tcp dport 80 meta nftrace set 1
nft monitor trace
```

Send a request from a pod, and watch which chains and rules the packet goes
through. Each packet gets a trace ID, and each line shows a table and chain,
the rule that matched, and its verdict:

```text
trace id ee464b08 ip kdbg-trace pre packet: iif "cali8a1b2c3d4e5" ip saddr 10.244.1.5 ip daddr 10.96.142.17 ... tcp dport 80 tcp flags == syn
trace id ee464b08 ip kdbg-trace pre rule ip daddr 10.96.142.17 tcp dport 80 meta nftrace set 1 (verdict continue)
trace id ee464b08 ip kube-proxy nat-prerouting rule jump services (verdict jump services)
trace id ee464b08 ip kube-proxy services rule ip daddr . meta l4proto . th dport vmap @service-ips (verdict goto service-ULMVA6XW-my-namespace/my-svc/tcp/http)
...
```

The last verdict for a packet tells you what happened to it: `accept`, `drop`,
or a NAT rule that rewrote it. Then remove the table:

```sh
nft delete table ip kdbg-trace
```

For traffic started on the node itself, use `hook output` instead of
`hook prerouting`. Match as narrowly as you can: every matching packet produces
several lines.

### See every firewall rule on the node

```sh
nft list tables
```

```text
table ip filter
table ip nat
table ip mangle
table ip kube-proxy
table ip6 kube-proxy
table inet firewalld
```

This tells you at a glance who installs rules on the node: `iptables` users
(`ip filter`, `ip nat`), kube-proxy, a host firewall like firewalld, or a CNI.
A host firewall dropping pod or node traffic is a common cause of problems on
self-managed nodes.

## Pitfalls

- **Wrong network, wrong rules.** In a regular pod you see the pod's rules,
  usually none. kube-proxy's are on the node.
- **Legacy iptables rules are invisible to `nft`.** If the node uses legacy
  iptables, those rules don't show up here. See
  [iptables](iptables.md#legacy-and-nf_tables).
- **Version differences.** If the node's kernel or tools use features newer
  than kdbg's `nft`, some rules may be shown incompletely or fail to list.
  Use the node's own tool with `chroot /host nft list ruleset`.
- **Don't change other programs' tables.** kube-proxy and CNIs rewrite their
  tables regularly. Put temporary rules in a table of your own, as in the
  tracing recipe, and delete it afterwards.
- **Don't edit `iptables-nft` tables with `nft`.** `iptables` may fail to read
  rules it didn't write.
- **kube-proxy's rules have no counters**, so you can't see hits from listing
  them. Use tracing.

## Related

- [iptables](iptables.md), for kube-proxy's iptables mode and `iptables-nft`
  rules
- [conntrack](conntrack.md), for connections already set up by these rules
- [tcpdump](tcpdump.md), to see packets on the interfaces

## Manuals

- [nft](https://www.netfilter.org/projects/nftables/manpage.html)
- [nftables wiki](https://wiki.nftables.org/)
- [kube-proxy nftables mode](https://kubernetes.io/docs/reference/networking/virtual-ips/#proxy-mode-nftables)
