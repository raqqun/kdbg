# ping

`ping` sends ICMP echo requests to a host and reports the replies. It answers
three basic questions: can I reach this host at all, how long does a round trip
take, and are packets getting lost?

kdbg has the `iputils` version of `ping`, which has more options than the
busybox one. The same package also provides `tracepath` and `arping`, described
at the end of this page.

## When to use it in a cluster

- A first check that another pod or a node can be reached at the network level.
- Measuring latency between pods, for example on the same node versus across
  nodes or zones.
- Finding packet loss on a link.
- Finding MTU problems, where small packets get through but large ones don't.

## Privileges

`ping` needs either the `NET_RAW` capability, or the kernel setting
`net.ipv4.ping_group_range` to allow unprivileged ICMP for the pod's group. Some
container runtimes set this up for every pod, so `ping` often works without
extra privileges. If it fails with `Operation not permitted`, see
[Privileges](README.md#privileges).

`ping_group_range` is a "safe" sysctl, so you can also set it in the pod spec
without adding capabilities:

```yaml
spec:
  securityContext:
    sysctls:
      - name: net.ipv4.ping_group_range
        value: "0 2147483647"
```

## Common commands

```sh
ping -c 4 10.244.2.15             # Send 4 pings and stop
ping -c 100 -i 0.2 -q 10.244.2.15 # 100 pings, 5 per second, only print the summary
ping -c 10 -W 1 10.244.2.15       # Wait at most 1 second for each reply
ping -w 30 10.244.2.15            # Stop after 30 seconds, however many were sent
ping -O 10.244.2.15               # Report each missing reply as it happens
ping -D 10.244.2.15               # Prefix each line with a timestamp
ping -n 10.244.2.15               # Don't look up names for addresses
ping -4 my-svc                    # Force IPv4 (or -6 for IPv6)
ping -I eth0 10.244.2.15          # Send from a specific interface
ping -s 1400 -M do 10.244.2.15    # 1400-byte payload, don't let it be fragmented
```

## Reading the output

```text
PING 10.244.2.15 (10.244.2.15) 56(84) bytes of data.
64 bytes from 10.244.2.15: icmp_seq=1 ttl=62 time=0.712 ms
64 bytes from 10.244.2.15: icmp_seq=2 ttl=62 time=0.488 ms
64 bytes from 10.244.2.15: icmp_seq=4 ttl=62 time=0.501 ms

--- 10.244.2.15 ping statistics ---
4 packets transmitted, 3 received, 25% packet loss, time 3004ms
rtt min/avg/max/mdev = 0.488/0.567/0.712/0.101 ms
```

- **`icmp_seq`** numbers each ping. A gap (no `3` above) is a lost packet. With
  `-O`, `ping` prints `no answer yet for icmp_seq=3` instead of leaving a gap.
- **`time`** is the round-trip time. Between pods in the same cluster, expect
  well under a millisecond on the same node and around a millisecond across
  nodes in the same zone. Across zones it's usually a few milliseconds.
- **`ttl`** drops by one at every router on the way. Comparing it between
  targets tells you roughly how many hops away each one is. The starting value
  is usually 64.
- **`mdev`** is how much the round-trip time varies. A high value compared to
  the average means jitter.

Other messages:

| Message | Meaning |
| --- | --- |
| `Destination Host Unreachable` from your own IP | Your side couldn't find the target on the local network (no ARP reply). On a node, the target pod or node is down or on another network. |
| `Destination Host Unreachable` from another IP | A router on the way has no route to the target. |
| `Destination Port Unreachable` / `Packet filtered` | A firewall rejected the packet. |
| `Time to live exceeded` | Packets loop or the path is longer than the TTL. Often a routing loop. |
| `ping: bad address` / `Name does not resolve` | DNS failed, not the network. See [DNS tools](dns.md). |
| `ping: sendmsg: Operation not permitted` | Missing privileges, or a local firewall rule blocks ICMP. |
| `ping: sendmsg: Message too large` | With `-M do`: your packet is bigger than your own interface's MTU. |
| `Frag needed and DF set (mtu = 1400)`, then `local error: message too long, mtu=1400` | With `-M do`: a router on the path reported that it can only pass packets up to 1400 bytes. |
| No replies, no error | The packets, or the replies, are dropped somewhere without a message. |

## Recipes

### Compare latency on the same node and across nodes

Start two kdbg pods on the same node and one on another, with `nodeName` (see
[Privileges](README.md#privileges) for the `--overrides` form), then from one
of them:

```sh
ping -c 50 -q <pod-on-same-node>
ping -c 50 -q <pod-on-other-node>
```

Same-node traffic stays inside the node. Cross-node traffic goes through the
network between nodes, and through the overlay (VXLAN, Geneve, IP-in-IP) if your
CNI uses one. A big difference, or loss only across nodes, points to that
network or to the overlay.

### Find an MTU problem

Symptoms: connections open, small requests work, but large responses or TLS
handshakes hang. Packets bigger than some link on the path get dropped.

First check your interface's MTU:

```sh
ip link show eth0    # look for "mtu 1450" or similar
```

Then send packets that fill it exactly, with fragmentation forbidden. The
payload size is the MTU minus 28 bytes of IP and ICMP headers:

```sh
ping -c 3 -M do -s 1422 <target>   # For an MTU of 1450
ping -c 3 -M do -s 1472 <target>   # For an MTU of 1500
```

One byte more than that (`-s 1423` for an MTU of 1450) should fail at once with
`ping: sendmsg: Message too large`. That confirms you have the right size.

If small pings work but the full-size ones get no replies, something on the
path has a smaller MTU than your interface, and drops the packets without
saying so. Lower `-s` until replies come back to find the
real limit. Overlay networks add their own headers (VXLAN adds 50 bytes), so the
pod MTU has to be smaller than the node's. A CNI configured with the wrong MTU
causes exactly this problem.

`tracepath` (below) finds the path MTU for you.

### Watch for loss over a longer time

```sh
ping -D -O 10.244.2.15 | grep -E 'no answer|time='
```

Leave it running while you reproduce a problem. The timestamps let you match
lost packets to events like deployments or node load.

## Pitfalls

- **You usually can't ping a Service's ClusterIP.** With kube-proxy in
  iptables or nftables mode, a ClusterIP isn't attached to any interface. Only
  the Service's ports (TCP, UDP or SCTP) are forwarded, so ICMP to it gets no
  reply. In IPVS mode the node answers instead of a pod. Either way, `ping`
  tells you nothing about a Service. Test the Service's port with [nc](nc.md).
- **ICMP isn't covered by NetworkPolicy rules**, which only name TCP, UDP and
  SCTP. What happens to ICMP when a policy selects the pod depends on the CNI.
  Often it gets dropped unless a rule allows all ports. So a failed ping
  doesn't mean TCP traffic is blocked, and a working ping doesn't mean it's
  allowed.
- **Cloud networks and firewalls often drop ICMP.** Plenty of hosts on the
  internet, and some cloud load balancers, never answer pings. No reply
  doesn't mean the host is down.
- **Low latency doesn't mean a healthy application.** ICMP replies come from the
  kernel. A pod can answer pings while its application is stuck.

## tracepath

`tracepath` traces the route to a host and reports the path MTU, without
needing any privileges:

```sh
tracepath -n 10.244.2.15
```

```text
 1?: [LOCALHOST]                      pmtu 1450
 1:  10.244.1.1                                            0.093ms
 2:  10.244.2.15                                           0.611ms reached
     Resume: pmtu 1450 hops 2 back 2
```

`pmtu` is the largest packet that fits through the whole path. If it's smaller
than your interface's MTU, you've found an MTU problem.

## arping

`arping` sends ARP requests, which only work on the local network segment. It's
mostly useful on a node (with `kubectl debug node/<node>`) to check whether
another machine on the same network answers, or whether two machines claim the
same IP:

```sh
arping -c 3 -I eth0 192.168.1.20     # Who has this IP?
arping -D -c 3 -I eth0 192.168.1.20  # Duplicate address check: exit status 1 if someone else has it
```

It needs `NET_RAW`.

## Related

- [mtr](mtr.md), to see loss and latency at every hop, not only the end
- [tcptraceroute](tcptraceroute.md), when ICMP is blocked but a TCP port is open
- [nc](nc.md), to test a port instead of ICMP
- [ip](ip.md), for interfaces, MTU and routes

## Manuals

- [ping](https://manpages.debian.org/stable/iputils-ping/ping.8.en.html)
- [tracepath](https://manpages.debian.org/stable/iputils-tracepath/tracepath.8.en.html)
- [arping](https://manpages.debian.org/stable/iputils-arping/arping.8.en.html)
