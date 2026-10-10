# iperf3

`iperf3` measures how much data the network can carry between two machines.
One side runs as a server, the other as a client, and the client sends as much
data as it can for a while and reports the bandwidth, retransmissions and, for
UDP, jitter and packet loss.

## When to use it in a cluster

- Measuring bandwidth between pods on the same node, across nodes, and across
  zones.
- Finding out whether the CNI or overlay costs a lot of bandwidth, by comparing
  pod-to-pod with node-to-node.
- Checking a suspected slow node or network link.
- Measuring packet loss and jitter with UDP, for example for media or game
  traffic.

## Privileges

None. The server listens on port 5201 by default, so NetworkPolicies have to
allow it.

## Common commands

On the server side:

```sh
iperf3 -s                 # Listen on port 5201, serve tests one after another
iperf3 -s -1              # Serve one test, then exit
iperf3 -s -p 5202         # Use another port
```

On the client side:

```sh
iperf3 -c 10.244.2.15                 # 10-second TCP test, client sends
iperf3 -c 10.244.2.15 -t 30           # 30 seconds
iperf3 -c 10.244.2.15 -R              # Reverse: server sends, client receives
iperf3 -c 10.244.2.15 --bidir         # Both directions at once
iperf3 -c 10.244.2.15 -P 4            # 4 parallel streams
iperf3 -c 10.244.2.15 -O 2            # Leave out the first 2 seconds from the results
iperf3 -c 10.244.2.15 -u -b 500M      # UDP at 500 Mbit/s
iperf3 -c 10.244.2.15 -J > result.json  # JSON output
```

| Option | What it does |
| --- | --- |
| `-c HOST` | Run as client, connect to this server |
| `-t N` | Test duration in seconds (default 10) |
| `-i N` | Report every N seconds (default 1) |
| `-R` | Reverse direction: server sends to client |
| `--bidir` | Test both directions at the same time |
| `-P N` | N parallel streams |
| `-O N` | Omit the first N seconds, while TCP ramps up |
| `-u` | UDP instead of TCP |
| `-b RATE` | Target rate, like `100M` or `2G`. Required for useful UDP tests. |
| `-l SIZE` | Size of each write. For UDP, the datagram size. |
| `-p PORT` | Server port |
| `-4`, `-6` | Force IPv4 or IPv6 |
| `-J` | JSON output |
| `--get-server-output` | Also show the server's report |

## Reading the output

TCP:

```text
[ ID] Interval           Transfer     Bitrate         Retr  Cwnd
[  5]   0.00-1.00   sec   1.08 GBytes  9.29 Gbits/sec   12   1.21 MBytes
[  5]   1.00-2.00   sec   1.10 GBytes  9.42 Gbits/sec    0   1.32 MBytes
...
- - - - - - - - - - - - - - - - - - - - - - - - -
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-10.00  sec  10.9 GBytes  9.38 Gbits/sec   31             sender
[  5]   0.00-10.00  sec  10.9 GBytes  9.37 Gbits/sec                  receiver
```

- **Bitrate on the `receiver` line** is the result: what actually arrived.
- **Retr** is the number of TCP retransmissions: packets that had to be sent
  again. A few are normal. Many, together with low bitrate, mean packets get
  lost.
- **Cwnd** is TCP's congestion window. It grows while things go well and
  shrinks after losses.

UDP:

```text
[ ID] Interval           Transfer     Bitrate         Jitter    Lost/Total Datagrams
[  5]   0.00-10.00  sec   596 MBytes   500 Mbits/sec  0.012 ms  1203/431654 (0.28%)  receiver
```

- **Lost/Total** is the share of datagrams that never arrived.
- **Jitter** is how much the delay between datagrams varies.

## Recipes

### Compare same node, across nodes, and the node itself

Start a server pod on one node. Pin it with `nodeName`:

```sh
kubectl run iperf-server --image=ghcr.io/raqqun/kdbg \
  --overrides='{"spec":{"nodeName":"node-a"}}' -- iperf3 -s
kubectl get pod iperf-server -o wide      # Note its IP
```

Run a client on the same node, then on another node:

```sh
kubectl run iperf-client -it --rm --restart=Never --image=ghcr.io/raqqun/kdbg \
  --overrides='{"spec":{"nodeName":"node-a"}}' -- iperf3 -c <server-ip> -t 20 -O 2

kubectl run iperf-client -it --rm --restart=Never --image=ghcr.io/raqqun/kdbg \
  --overrides='{"spec":{"nodeName":"node-b"}}' -- iperf3 -c <server-ip> -t 20 -O 2
```

Then repeat between the nodes themselves, using pods with host networking, to
leave the CNI out:

```sh
kubectl run iperf-server-host --image=ghcr.io/raqqun/kdbg \
  --overrides='{"spec":{"nodeName":"node-a","hostNetwork":true}}' -- iperf3 -s

kubectl run iperf-client-host -it --rm --restart=Never --image=ghcr.io/raqqun/kdbg \
  --overrides='{"spec":{"nodeName":"node-b","hostNetwork":true}}' -- iperf3 -c <node-a-ip> -t 20 -O 2
```

How to read the results:

- **Same node** should be very fast, since traffic never leaves the machine.
  If it's slow, the node is short on CPU, or the pod's CPU limits get in the
  way.
- **Node to node** is what the network between nodes can carry.
- **Pod to pod across nodes** compared to node to node is the cost of the
  CNI. With an overlay, losing some bandwidth is expected. Losing a lot
  points to MTU problems or missing hardware offloading for the overlay.

Host networking pods need a namespace that allows them under Pod Security
Admission. Delete the server pods when you're done.

### Through a Service

To include kube-proxy's forwarding in the test:

```sh
kubectl expose pod iperf-server --port=5201
iperf3 -c iperf-server -t 20 -O 2
```

### UDP loss and jitter

```sh
iperf3 -c <server-ip> -u -b 200M -t 30
```

Raise `-b` step by step. The point where loss starts climbing is roughly what
the path can carry for UDP.

## Pitfalls

- **UDP tests run at 1 Mbit/s unless you set `-b`.** Always set it.
- **CPU limits cap the results.** Sending and receiving at high rates takes CPU.
  A pod with a low CPU limit gets throttled and reports low bandwidth that has
  nothing to do with the network. Run test pods without CPU limits, or with
  generous ones.
- **One TCP stream often can't fill a fast link.** Try `-P 4` or more before
  concluding a link is slow.
- **The start of a test is slower** while TCP ramps up. Use `-O 2` and tests of
  20 seconds or more.
- **The server handles one test at a time.** A second client gets
  `the server is busy running a test`. Wait, or start more servers on other
  ports.
- **Cloud bandwidth limits.** Many cloud instance types allow bursts above
  their sustained bandwidth for a short time. A long test can show the speed
  dropping halfway. That's the instance limit, not a network fault.
- **Results vary.** Run each test a few times, and at different times of day
  if the nodes are shared.

## Related

- [ping](ping.md), for latency and MTU checks
- [mtr](mtr.md), to find where on the path loss happens
- [iptraf-ng](iptraf-ng.md), to watch traffic on the interfaces during a test

## Manual

- [iperf3](https://software.es.net/iperf/invoking.html)
