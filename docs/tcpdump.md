# tcpdump

`tcpdump` captures the packets going through a network interface and prints
them, or saves them to a file you can open in Wireshark. It's the most direct
way to answer "does the traffic actually arrive here, and what does it look
like?" Other tools tell you a connection failed. `tcpdump` shows you the
packets that were sent, and the ones that never got an answer.

## When to use it in a cluster

- Checking whether traffic from a client actually reaches a pod.
- Seeing whether a pod replies, and what it replies.
- Finding where in the path packets disappear, by capturing at several points
  (client pod, client node, server node, server pod).
- Watching DNS queries and answers.
- Recording traffic to analyse later in Wireshark.

## Privileges

`tcpdump` needs `NET_RAW`. With `-i any` it warns that promiscuous mode isn't
supported, which is harmless. If it refuses to start because of promiscuous
mode on a specific interface, add `-p`. In a pod, promiscuous mode makes no
difference anyway. See
[Privileges](README.md#privileges).

To capture a specific pod's traffic, attach kdbg to it:

```sh
kubectl debug -it <pod> --image=ghcr.io/raqqun/kdbg --target=<container> --profile=netadmin -- bash
```

To capture on a node:

```sh
kubectl debug node/<node> -it --image=ghcr.io/raqqun/kdbg --profile=sysadmin -- bash
```

## Common commands

```sh
tcpdump -i any -nn port 8080                 # Everything to or from port 8080, on all interfaces
tcpdump -i eth0 -nn host 10.244.2.15         # Everything to or from one IP
tcpdump -i any -nn -c 50 port 53             # Stop after 50 packets
tcpdump -i any -nn -A port 80                # Show packet contents as text (for HTTP)
tcpdump -i any -nn -X port 6379              # Show contents as hex and text
tcpdump -i any -nn -v icmp                   # ICMP, with more detail
tcpdump -i any -nn -w /tmp/cap.pcap port 443 # Save to a file instead of printing
tcpdump -nn -r /tmp/cap.pcap                 # Read a saved file
tcpdump -i any -nn -tttt port 80             # Full date and time on each packet
tcpdump -i any -nn -Q in port 80             # Only incoming packets (-Q out for outgoing)
tcpdump -D                                   # List interfaces you can capture on
```

| Option | What it does |
| --- | --- |
| `-i IFACE` | Interface to capture on. `any` means all of them. |
| `-nn` | Don't look up names for IPs or ports. Always use it: lookups are slow and add their own traffic. |
| `-c N` | Stop after N packets |
| `-w FILE` | Write packets to a file (pcap format) |
| `-r FILE` | Read packets from a file |
| `-A`, `-X` | Show packet contents as text, or as hex and text |
| `-v`, `-vv` | More details: TTL, IP options, checksums |
| `-e` | Show MAC addresses |
| `-s N` | Capture only the first N bytes of each packet. Smaller files when you only need headers. |
| `-l` | Flush each line, for piping to `grep` |
| `-U` | With `-w`, write each packet immediately |
| `-p` | Don't use promiscuous mode |
| `-C MB -W N` | Rotate files: at most N files of MB megabytes each |

## Filters

The expression at the end chooses which packets to capture. Combine parts with
`and`, `or`, `not` and parentheses (quote the expression when you use
parentheses).

```sh
host 10.244.2.15                    # To or from this IP
src host 10.244.2.15                # Only from it
dst port 443                        # Only to this port
net 10.244.0.0/16                   # To or from anything in this range
port 80 or port 443
tcp and not port 22
udp port 53
icmp
portrange 30000-32767               # NodePorts
'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0'   # Only connection attempts and resets
'host 10.244.2.15 and (port 80 or port 8080)'
```

## Reading the output

```text
10:41:02.118201 eth0  Out IP 10.244.1.5.43210 > 10.244.2.15.8080: Flags [S], seq 2849102947, win 64860, options [mss 1410,sackOK,TS val 1 ecr 0,nop,wscale 7], length 0
10:41:02.118904 eth0  In  IP 10.244.2.15.8080 > 10.244.1.5.43210: Flags [S.], seq 1093722, ack 2849102948, win 64308, options [...], length 0
10:41:02.118931 eth0  Out IP 10.244.1.5.43210 > 10.244.2.15.8080: Flags [.], ack 1, win 507, length 0
10:41:02.119015 eth0  Out IP 10.244.1.5.43210 > 10.244.2.15.8080: Flags [P.], seq 1:79, ack 1, win 507, length 78: HTTP: GET / HTTP/1.1
```

Each line is one packet: time, interface and direction (with `-i any`), source
`IP.port`, destination `IP.port`, then protocol details.

TCP flags:

| Flags | Meaning |
| --- | --- |
| `[S]` | SYN: opening a connection |
| `[S.]` | SYN-ACK: the server accepts |
| `[.]` | ACK only |
| `[P.]` | Data being sent |
| `[F.]` | FIN: one side is closing |
| `[R]` or `[R.]` | Reset: connection refused or aborted |

### Patterns to recognise

**The connection works:** `[S]`, `[S.]`, `[.]`, then data in both directions.

**Packets are dropped before reaching the server:** the client sends `[S]`,
nothing comes back, and the client sends `[S]` again after about 1, 2, 4, 8
seconds:

```text
10:41:02.11 Out IP 10.244.1.5.43210 > 10.244.2.15.8080: Flags [S], seq 284910...
10:41:03.12 Out IP 10.244.1.5.43210 > 10.244.2.15.8080: Flags [S], seq 284910...
10:41:05.13 Out IP 10.244.1.5.43210 > 10.244.2.15.8080: Flags [S], seq 284910...
```

Capture on the server side too. If the SYN arrives there and the server
replies, the reply is lost on the way back. If it never arrives, it's lost on
the way there.

**Nothing listens on the port:** `[S]` answered straight away by `[R.]`.

**The server or something in between aborts the connection:** a normal start,
then a `[R]` in the middle. Check which side sent it.

**Retransmissions:** the same `seq` sent again. A few are normal. Many point
to packet loss.

**ICMP errors** like `ICMP 10.244.2.15 udp port 9999 unreachable` or
`ICMP host 10.244.2.15 unreachable` come back from whoever couldn't deliver
the packet.

**DNS:** queries and answers are decoded:

```text
IP 10.244.1.5.51234 > 10.96.0.10.53: 4512+ A? my-svc.my-namespace.svc.cluster.local. (55)
IP 10.96.0.10.53 > 10.244.1.5.51234: 4512*- 1/0/0 A 10.96.142.17 (108)
```

## Where to capture

The same connection looks different depending on where you capture it.

**In the client pod** you see traffic exactly as the application sends it.
Connections to a Service go to the Service's ClusterIP.

**On the client's node**, the pod's traffic first arrives on the node side of
the pod's virtual interface (a `veth`, or `lxc*` with Cilium). It still goes to
the ClusterIP there. kube-proxy's rules then rewrite the destination to one of
the Service's pods, so on the node's main interface you see the pod IP.

**Between nodes**, if the CNI uses an overlay, the pod traffic is wrapped in
VXLAN, Geneve or IP-in-IP. On the node's main interface you see node IPs on
the outside, and the pod traffic inside. See
[Overlay networks](#overlay-networks).

**On the server's node and in the server pod** you see the traffic arrive with
the pod IP as destination. With `externalTrafficPolicy: Cluster`, or SNAT
somewhere on the way, the source may be a node IP instead of the client's.

Some CNIs (Cilium, for example) handle Services before packets leave the pod's
socket. Then even in the client pod you see the pod IP, not the ClusterIP.

### Find a pod's interface on its node

Inside the pod (or a kdbg attached to it), get the index of the other end of
its interface:

```sh
cat /sys/class/net/eth0/iflink     # e.g. 17
```

On the node, the interface with that index is the pod's:

```sh
ip -o link | grep '^17:'
tcpdump -i <that interface> -nn
```

## Recipes

### Does traffic reach the pod?

Attach kdbg to the server pod and capture on its port:

```sh
tcpdump -i any -nn port 8080
```

Then send a request from the client. No packets: the traffic doesn't reach the
pod. Look at the Service, the NetworkPolicies and the client side. Packets in,
but no replies: the application doesn't answer, or answers from another port
or address.

### Save a capture and open it in Wireshark

```sh
tcpdump -i any -nn -w /tmp/cap.pcap port 8080
# reproduce the problem, then Ctrl+C
```

From your own machine:

```sh
kubectl cp <namespace>/<pod>:/tmp/cap.pcap ./cap.pcap -c <debug-container>
wireshark cap.pcap
```

Or stream straight to Wireshark on your machine, without saving in the pod:

```sh
kubectl exec <pod> -c <debug-container> -- tcpdump -i any -nn -U -w - port 8080 | wireshark -k -i -
```

### Leave a capture running safely

On a busy pod or node, captures grow fast. Rotate files so they can't fill the
disk:

```sh
tcpdump -i any -nn -s 200 -C 50 -W 10 -w /tmp/cap.pcap port 8080
```

This keeps the last 10 files of 50 MB each, and only the first 200 bytes of
each packet, which covers the headers.

### Overlay networks

On a node, overlay traffic between nodes uses its own UDP port:

| Overlay | Traffic |
| --- | --- |
| VXLAN (standard port, Calico, Cilium) | `udp port 4789` or `udp port 8472` |
| VXLAN (Flannel) | `udp port 8472` |
| Geneve (Cilium, OVN) | `udp port 6081` |
| IP-in-IP (Calico) | `ip proto 4` |
| WireGuard (encrypted) | `udp port 51820`, contents unreadable |

`tcpdump` decodes VXLAN on port 4789 automatically. For port 8472, tell it:

```sh
tcpdump -i eth0 -nn -T vxlan udp port 8472
```

Often it's simpler to capture on the overlay's own interface (`flannel.1`,
`vxlan.calico`, `cilium_vxlan`, `tunl0`), where packets are already unwrapped.

## Pitfalls

- **Without `-nn`, tcpdump looks up names**, which is slow and adds DNS
  traffic to what you're capturing.
- **Captures can be huge.** Always filter, and use `-c` or `-C`/`-W` on busy
  machines. Write to `/tmp`, and remember the container's disk is limited.
- **Packets bigger than the MTU, and "bad checksum" messages**, are normal on
  nodes. Network cards merge and split packets, and compute checksums, after
  `tcpdump` sees them.
- **Encrypted traffic stays encrypted.** You can see TLS handshakes and
  packet sizes but not contents. Encrypted CNIs (WireGuard, IPsec) hide even
  the pod IPs between nodes.
- **`-i any` doesn't show MAC addresses**, because it uses a different format.
  Capture on a specific interface with `-e` if you need them.
- **Filters on ClusterIPs only work where the ClusterIP is still visible.** See
  [Where to capture](#where-to-capture).

## Related

- [iptraf-ng](iptraf-ng.md), for a live overview instead of every packet
- [ip](ip.md), to find interfaces and routes
- [iptables](iptables.md), [nft](nft.md) and [conntrack](conntrack.md), to
  see what the node does with the packets
- [socat](socat.md), to see the contents of a connection without capturing

## Manuals

- [tcpdump](https://www.tcpdump.org/manpages/tcpdump.1.html)
- [Filter syntax](https://www.tcpdump.org/manpages/pcap-filter.7.html)
