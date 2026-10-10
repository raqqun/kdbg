# tcptraceroute

`tcptraceroute` traces the path to a host using TCP SYN packets, the same kind
of packet that opens a real connection. Classic `traceroute` uses UDP or ICMP,
which firewalls often drop. A firewall that lets your application's traffic
through usually lets these probes through too, so `tcptraceroute` gets further.

At the end of the trace it also tells you whether the port is open or closed.

## When to use it in a cluster

- A connection to a host and port hangs, and you want to know where the
  packets stop: inside the node, at a cloud firewall, at the destination.
- Checking that egress to an external service leaves the cluster the way you
  expect.
- Telling apart "port closed" (the host answered, nothing listens) from "packets
  dropped on the way".

## Privileges

`tcptraceroute` needs `NET_RAW`. See [Privileges](README.md#privileges).

## Common commands

```sh
tcptraceroute example.com 443          # Trace to port 443 (default port: 80)
tcptraceroute -n example.com 443       # Don't look up names of hops
tcptraceroute -n -q 1 -w 1 example.com 443   # 1 probe per hop, wait 1 second: much faster
tcptraceroute -n -m 15 example.com 443 # At most 15 hops
tcptraceroute -n -f 3 example.com 443  # Start at hop 3, skipping the ones you know
tcptraceroute -i eth0 example.com 443  # Use a specific interface
```

| Option | What it does |
| --- | --- |
| `-n` | No DNS lookups for hops |
| `-q N` | Probes per hop (default 3) |
| `-w SECONDS` | How long to wait for each reply (default 3) |
| `-m N` | Maximum hops (default 30) |
| `-f N` | First hop to probe |
| `-i IFACE` | Interface to send from |
| `-s ADDR` | Source address |
| `-p PORT` | Source port |
| `-A` | Send ACK packets instead of SYN. Gets through some firewalls that only check new connections. |

## Reading the output

```text
Selected device eth0, address 10.244.1.5, port 40211 for outgoing packets
Tracing the path to example.com (203.0.113.10) on TCP port 443 (https), 30 hops max
 1  10.244.1.1  0.071 ms  0.040 ms  0.037 ms
 2  10.0.1.1  0.512 ms  0.433 ms  0.410 ms
 3  * * *
 4  198.51.100.1  2.104 ms  2.034 ms  2.021 ms
 5  203.0.113.10 [open]  11.902 ms  11.733 ms  11.690 ms
```

- **Each line is a hop**, with the time each probe took to come back.
- **`* * *`** means no reply came from that hop. If later hops answer, the
  router just doesn't send replies. If the trace ends in stars and never
  reaches the target, packets are dropped after the last hop that answered, or
  the replies are dropped on their way back.
- **`[open]`** at the end: the target answered with SYN-ACK. Something listens
  on the port, and the path works.
- **`[closed]`** at the end: the target answered with a reset. The path works,
  but nothing listens on that port, or a firewall sends resets for it.

## Recipes

### Where does a connection to an external service get stuck?

```sh
tcptraceroute -n -q 1 -w 2 db.example.com 5432
```

Compare the last hop that answers with what you know about the network:

- Stops after hop 1 (the node): the node itself drops it. Look at node firewall
  rules ([iptables](iptables.md), [nft](nft.md)) and egress NetworkPolicies.
- Stops inside the cloud network: a security group, network ACL or routing
  table.
- Reaches the target with `[closed]`: the network is fine. The service isn't
  listening on that port, or its own firewall rejects you.

### Compare from the pod and from the node

Run the same trace in a kdbg pod and on its node (`kubectl debug node/<node>`).
If the node gets through and the pod doesn't, the pod's traffic is treated
differently. Common reasons are an egress NetworkPolicy, or an external
firewall that allows the node's IP but not the IP that pod traffic leaves
with.

## Pitfalls

- **ICMP replies have to get back to you.** Each hop answers with an ICMP
  "time exceeded" message. If ICMP is filtered on the way back, hops show `*`
  even though the probes went through.
- **The final hop is what counts.** `[open]` means the path works, however
  many stars come before it.
- **`Selected device` matters.** If the pod or node has several interfaces and
  the wrong one is chosen, pass `-i`.
- **Errors like `error opening device` or `pcap` errors** usually mean
  missing `NET_RAW`.

## Other tracing tools in kdbg

- [`mtr -T -P <port>`](mtr.md) does the same with live loss and latency per
  hop, and keeps running.
- `traceroute` (busybox) uses UDP or ICMP (`-I`).
- `tracepath` (see [ping](ping.md#tracepath)) needs no privileges and reports
  the path MTU.

## Related

- [nc](nc.md), for a quick "can I connect?" test
- [nmap](nmap.md), to check many ports at once
- [tcpdump](tcpdump.md), to see what happens to the SYN packets on the node

## Manual

- [tcptraceroute](https://manpages.debian.org/stable/tcptraceroute/tcptraceroute.1.en.html)
