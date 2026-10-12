# conntrack

The Linux kernel keeps a table of every connection going through a machine:
the connection tracking (conntrack) table. Whenever traffic is NATed, as with
every connection to a Kubernetes Service, the table remembers the rewrite so
that replies can be translated back. Firewall rules also use it to tell new
connections from existing ones.

The `conntrack` tool lists, watches and deletes entries in this table, and
shows its statistics.

## When to use it in a cluster

- Seeing which pod a connection to a Service was actually sent to.
- Finding connections that get no reply.
- UDP traffic (often DNS) keeps going to a pod that no longer exists.
- Intermittent packet drops or 5-second DNS delays, caused by conntrack
  insert failures.
- The table is full and the node drops new connections.

## Privileges

`conntrack` needs `NET_ADMIN`. The table that matters for Services is the
node's:

```sh
kubectl debug node/<node> -it --image=ghcr.io/raqqun/kdbg --profile=sysadmin -- bash
```

Each network namespace has its own table, so in a regular pod you only see that
pod's own entries, if any.

## Common commands

```sh
conntrack -L                               # List all entries
conntrack -L -p tcp --dport 80             # TCP connections to port 80
conntrack -L -d 10.96.142.17               # Connections to this ClusterIP
conntrack -L --reply-src 10.244.2.15       # Connections answered by this pod
conntrack -L -p udp --dport 53             # DNS
conntrack -L -g                            # Only connections whose destination was rewritten (DNAT)
conntrack -L -n                            # Only connections whose source was rewritten (SNAT)
conntrack -L -f ipv6                       # IPv6 entries
conntrack -C                               # Number of entries
conntrack -S                               # Statistics per CPU
conntrack -E                               # Print new, updated and removed entries as they happen
conntrack -E -p tcp --dport 80             # Same, filtered
conntrack -D -p udp --reply-src 10.244.3.9 # Delete matching entries
```

| Option | What it does |
| --- | --- |
| `-L` | List entries |
| `-E` | Watch events live |
| `-D` | Delete matching entries |
| `-C` | Count entries |
| `-S` | Statistics |
| `-p tcp\|udp\|icmp` | Protocol |
| `-s`, `-d` | Original source or destination address |
| `--sport`, `--dport` | Original source or destination port |
| `--reply-src`, `--reply-dst` | Source or destination of the reply direction |
| `-g`, `-n` | Only DNATed or SNATed connections |
| `-f ipv6` | IPv6 instead of IPv4 |
| `-o extended` | Also show the protocol family |

## Reading an entry

```text
tcp      6 86397 ESTABLISHED src=10.244.1.5 dst=10.96.142.17 sport=43210 dport=80 src=10.244.2.15 dst=10.244.1.5 sport=8080 dport=43210 [ASSURED] mark=0 use=1
```

- **`tcp 6`**: protocol name and number.
- **`86397`**: seconds until the entry expires if no more traffic comes.
- **`ESTABLISHED`**: TCP state.
- **The first `src= dst= sport= dport=`** is the original direction: the pod
  `10.244.1.5` connected to the ClusterIP `10.96.142.17` on port 80.
- **The second set** is the reply the kernel expects: from `10.244.2.15:8080`.
  So the Service sent this connection to the pod `10.244.2.15`, port 8080.
  When the reply source differs from the original destination, the destination
  was rewritten (DNAT). When the reply destination differs from the original
  source, the source was rewritten (SNAT or masquerade).
- **`[ASSURED]`**: traffic has been seen in both directions.
- **`[UNREPLIED]`**: no reply has been seen. The destination isn't answering,
  or its replies are lost.

## Recipes

### Which pod did a Service connection go to?

```sh
conntrack -L -d 10.96.142.17 -p tcp --dport 80
```

The reply source of each entry is the pod that got that connection. Useful
when only some requests fail: check whether they all go to the same pod.

### Connections that get no reply

```sh
conntrack -L | grep UNREPLIED
```

Many `[UNREPLIED]` entries to the same destination mean that destination
doesn't answer, or the replies take a different path back and never reach this
node. For TCP these show as `SYN_SENT`.

### UDP traffic stuck on a pod that's gone

UDP has no connections, but conntrack still keeps an entry for each flow until
it times out. If a Service's pod is replaced while a client keeps sending UDP
from the same source port, packets can keep going to the old pod's IP for as
long as the entry lives. kube-proxy deletes such entries when endpoints change,
but it doesn't catch every case.

Look for entries pointing to pod IPs that no longer exist:

```sh
conntrack -L -p udp --dport 53
```

Delete the stale ones by their reply source:

```sh
conntrack -D -p udp --reply-src 10.244.3.9
```

New packets then create fresh entries, which go to a current pod.

### Is the table full?

```sh
conntrack -C
sysctl net.netfilter.nf_conntrack_max
```

When the count reaches the maximum, the kernel drops packets of new
connections, and logs `nf_conntrack: table full, dropping packet` (see
`dmesg`). Nodes with many short connections hit this first. kube-proxy sets
the maximum based on the number of CPUs, and you can raise it in kube-proxy's
`conntrack` settings.

### Dropped packets and 5-second DNS delays

```sh
conntrack -S
```

```text
cpu=0   found=0 invalid=412 insert=0 insert_failed=37 drop=37 early_drop=0 error=0 search_restart=11 clash_resolve=208 chaintoolong=0
cpu=1   found=0 invalid=389 insert=0 insert_failed=29 drop=29 early_drop=0 error=0 search_restart=9 clash_resolve=187 chaintoolong=0
```

- **`insert_failed`** and **`drop`** growing: packets dropped because their
  entry couldn't be added. A known cause is two UDP packets from the same
  socket at the same moment, which is exactly what many resolvers do when they
  send A and AAAA queries in parallel. The client waits 5 seconds and
  retries, so DNS lookups take 5 seconds now and then. Fixes include
  NodeLocal DNSCache, or `options single-request-reopen` (glibc) in the pod's
  `dnsConfig`.
- **`clash_resolve`**: the same kind of collision, but the kernel sorted it
  out and nothing was dropped. Recent kernels resolve most of them, which is
  why the 5-second delays have become rarer. A high count here is harmless.
- **`early_drop`** growing: the table is full and old entries are being
  thrown out to make room.
- **`invalid`**: packets that didn't fit any known connection. Some are
  normal. Lots of them can point to asymmetric routing.

Run it twice, a minute apart, and compare: the totals since boot matter less
than how fast they grow.

### Watch connections being made

```sh
conntrack -E -p tcp --dport 80
```

```text
    [NEW] tcp      6 120 SYN_SENT src=10.244.1.5 dst=10.96.142.17 sport=43210 dport=80 [UNREPLIED] src=10.244.2.15 dst=10.244.1.5 sport=8080 dport=43210
 [UPDATE] tcp      6 60 SYN_RECV src=10.244.1.5 dst=10.96.142.17 sport=43210 dport=80 src=10.244.2.15 dst=10.244.1.5 sport=8080 dport=43210
 [UPDATE] tcp      6 86400 ESTABLISHED src=10.244.1.5 dst=10.96.142.17 sport=43210 dport=80 src=10.244.2.15 dst=10.244.1.5 sport=8080 dport=43210 [ASSURED]
[DESTROY] tcp      6 TIME_WAIT src=10.244.1.5 ...
```

A `[NEW]` that never gets an `[UPDATE]` is a connection that got no answer.

## Pitfalls

- **Wrong network, wrong table.** Service connections are tracked on the node,
  not in the pod. Use `kubectl debug node/<node>`.
- **Some CNIs keep their own table.** Cilium with eBPF tracks connections in its
  own maps, so the kernel's table shows little. Use
  `kubectl -n kube-system exec <cilium-pod> -- cilium-dbg bpf ct list global`.
- **Deleting entries breaks connections.** `-D` on TCP entries can reset or
  stall live connections. Filter as narrowly as possible. Never use `-F`
  (delete everything) on a production node.
- **Listing a big table is slow** and produces a lot of output. Always filter.
- **`Protocol not supported` or `Can't open handler`** means missing
  `NET_ADMIN`, or the conntrack module isn't loaded in that network namespace.

## Related

- [iptables](iptables.md) and [nft](nft.md), for the rules that create these
  entries
- [tcpdump](tcpdump.md), to see the packets of a connection
- [DNS tools](dns.md), for DNS problems in general

## Manuals

- [conntrack](https://manpages.debian.org/stable/conntrack/conntrack.8.en.html)
- [conntrack sysctls](https://docs.kernel.org/networking/nf_conntrack-sysctl.html)
