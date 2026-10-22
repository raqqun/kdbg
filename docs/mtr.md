# mtr

`mtr` combines `traceroute` and `ping`. It finds every router between you and a
target, then keeps sending probes to all of them and shows packet loss and
latency for each hop as it goes. Where `ping` tells you *that* packets get lost
or delayed, `mtr` helps you find *where*.

## When to use it in a cluster

- Traffic from a pod to an external service is slow or unreliable, and you want
  to know whether the problem is inside the cluster, in the cloud network, or
  further away.
- Traffic between nodes or zones is lossy, and you want to see at which hop.
- Checking which way egress traffic leaves the cluster (through a NAT gateway,
  a proxy, a specific router).

## Privileges

`mtr` needs `NET_RAW`. See [Privileges](README.md#privileges).

## Common commands

```sh
mtr 10.244.2.15                     # Interactive view, updates live
mtr -n example.com                  # Don't look up names of hops (faster, less noise)
mtr -rwn -c 100 example.com         # Send 100 probes, then print a report and exit
mtr -T -P 443 -rwn example.com      # Use TCP SYN probes to port 443 instead of ICMP
mtr -u -P 53 -rwn 10.96.0.10        # Use UDP probes to port 53
mtr -i 0.2 -c 300 -rwn example.com  # Probe faster: 5 per second
mtr -b example.com                  # Show both names and IPs
mtr -j -c 50 -n example.com         # JSON output, for scripts
```

Options that matter most:

| Option | What it does |
| --- | --- |
| `-r` | Report mode: run for `-c` cycles, print a summary, exit. Use it to paste results somewhere. |
| `-w` | Wide report: don't cut long host names. |
| `-c N` | Number of probes per hop (default 10 in report mode). |
| `-n` | No DNS lookups for hops. |
| `-T`, `-u` | TCP or UDP probes instead of ICMP. Use them when ICMP is blocked or treated differently. |
| `-P PORT` | Destination port for TCP or UDP probes. |
| `-i SECONDS` | Time between probes (default 1). |
| `-m N` | Maximum number of hops (default 30). |
| `-4`, `-6` | Force IPv4 or IPv6. |

In the interactive view, press `n` to toggle DNS, `d` to switch display modes,
`r` to reset counters, `p` to pause and `q` to quit.

## Reading the output

```text
HOST: kdbg                    Loss%   Snt   Last   Avg  Best  Wrst StDev
  1.|-- 10.244.1.1             0.0%   100    0.1   0.1   0.0   0.3   0.0
  2.|-- 10.0.1.1               0.0%   100    0.4   0.5   0.3   1.9   0.2
  3.|-- ???                   100.0   100    0.0   0.0   0.0   0.0   0.0
  4.|-- 172.16.4.9            40.0%   100    1.2   1.4   1.0   8.1   0.9
  5.|-- 203.0.113.17           0.0%   100   11.8  12.1  11.5  14.2   0.4
```

| Column | Meaning |
| --- | --- |
| `Loss%` | Share of probes to this hop that got no reply |
| `Snt` | Probes sent |
| `Last`, `Avg`, `Best`, `Wrst` | Round-trip times in milliseconds |
| `StDev` | How much the times vary. High means jitter. |

### Loss: real or not?

Routers treat probes addressed *through* them differently from probes addressed
*to* them. Many limit how many "time exceeded" replies they send. So:

- **Loss at a middle hop that doesn't continue to later hops** is not real
  loss. The router just didn't bother answering all probes, while still
  forwarding traffic fine. In the example, hop 4 shows 40% loss but hop 5 shows
  0%: ignore hop 4.
- **Loss that starts at a hop and continues at the same level or higher to the
  final hop is real.** The problem is at that hop or the link just before it.
- **`???`** is a hop that never answers. That's common and harmless as long
  as later hops answer.
- **Only the last hop counts for the end result.** If the final hop shows 0%
  loss, packets get through.

The same logic applies to latency: a jump at one hop that carries on through
all later hops is real (a long link, a slow router). A jump at one hop that
disappears again is that router being slow to answer, not slow to forward.

## What a path looks like from a pod

- **To a pod on the same node:** one hop, straight to the pod. Traffic doesn't
  leave the node.
- **To a pod on another node:** usually two hops. The first is the local
  node's side of the pod network (a bridge like `cni0` or a gateway address).
  With an overlay network (VXLAN, Geneve, IP-in-IP), the trip between nodes is
  wrapped in a tunnel and appears as a single hop, however many routers are
  really in between.
- **To the outside world:** the node, then the cloud network's routers, then
  possibly a NAT gateway or firewall, then the internet. Long gaps of `???` are
  common inside cloud networks.

Compare against the same `mtr` run from a node (`kubectl debug node/<node>`).
If the node shows no loss but the pod does, the problem is between the pod and
the node: the CNI, the overlay or a node-level firewall.

## Recipes

### A report to share

```sh
mtr -rwn -c 200 example.com
```

200 probes give stable loss numbers. Run it at the time the problem happens,
and once when things are fine, to compare.

### When ICMP gets a different treatment

Some networks prioritise, rate-limit or block ICMP. Probe with the protocol and
port the application really uses:

```sh
mtr -T -P 443 -rwn -c 100 api.example.com
```

If ICMP shows loss but TCP doesn't, the network is treating ICMP differently
and the application is probably fine.

### Through a Service

Probes to a Service's ClusterIP only go anywhere if they use the Service's
protocol and port, because only those are forwarded to a pod:

```sh
mtr -T -P 80 -rwn -c 50 10.96.142.17
```

## Pitfalls

- **Loss at middle hops is usually not a problem.** See
  [Loss: real or not?](#loss-real-or-not)
- **Overlays hide the network between nodes.** If you suspect the network
  between nodes, run `mtr` from one node to another node's IP, with
  `kubectl debug node/<node>`.
- **DNS lookups slow it down and add noise.** Use `-n` unless you need names.
- **Interactive mode needs a terminal.** Use `-r` when you run it through
  `kubectl exec` without `-t`, or in scripts.
- **Paths can change between runs.** Cloud networks and the internet balance
  traffic over several paths. `mtr` shows them as multiple IPs on the same hop.

## Related

- [ping](ping.md), for loss and latency to a single host, and MTU checks
- [tcptraceroute](tcptraceroute.md), for a one-off TCP trace showing whether the
  final port is open
- [iperf3](iperf3.md), to measure bandwidth once you know the path is fine

## Manual

- [mtr](https://manpages.debian.org/stable/mtr-tiny/mtr.8.en.html)
