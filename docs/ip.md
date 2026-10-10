# ip

`ip` shows and changes a machine's network setup: interfaces, addresses,
routes, the neighbour (ARP) table, and routing rules. In a pod it shows the
pod's own small network. On a node it shows how the CNI connects pods to each
other and to the outside world.

kdbg has the full `iproute2` version, not the busybox one, so all the options
below work.

## When to use it in a cluster

- Checking a pod's IP, interface and MTU.
- Finding out which way traffic to a given address leaves a pod or node.
- On a node: seeing the CNI's interfaces and routes, and finding which
  interface belongs to which pod.
- Spotting interfaces with errors or dropped packets.
- Checking for failed neighbour (ARP) entries.

## Privileges

Reading needs no privileges. Changing anything needs `NET_ADMIN`. On a node,
changes affect the real node: be careful.

## Common commands

```sh
ip -br addr                  # One line per interface: name, state, addresses
ip addr show eth0            # Full details for one interface
ip -br link                  # Interfaces and their state, no addresses
ip link show eth0            # MTU, state, MAC address
ip -s link show eth0         # Packet, error and drop counters
ip -d link show eth0         # Interface type details (veth, vxlan, bridge...)
ip route                     # Main routing table
ip route get 10.96.0.10      # Which route, interface and source address a packet to this IP would use
ip neigh                     # Neighbour (ARP) table
ip rule                      # Policy routing rules
ip route show table all      # Routes in every table
ip -j -p addr                # Any command as JSON (-p: pretty)
ip monitor                   # Print changes to links, addresses and routes as they happen
```

Most commands can be shortened: `ip a`, `ip l`, `ip r`, `ip n`.

## What a pod looks like

```sh
ip -br addr
```

```text
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if17        UP             10.244.1.5/24 fe80::a8c3:2bff:fe11:9e40/64
```

- **`eth0`** is the pod's interface. It's one end of a virtual cable (a `veth`
  pair). The other end is on the node.
- **`@if17`** is the index of the other end on the node. See
  [Find a pod's interface on its node](#find-a-pods-interface-on-its-node).
- **`10.244.1.5/24`** is the pod's IP, from the pod network range of its node.

```sh
ip route
```

```text
default via 10.244.1.1 dev eth0
10.244.1.0/24 dev eth0 proto kernel scope link src 10.244.1.5
```

Everything that isn't on the local range goes to the gateway, which is the
node. What the gateway looks like depends on the CNI:

| CNI | Typical pod route |
| --- | --- |
| Flannel, bridge-based CNIs | `default via 10.244.1.1`: the node's bridge (`cni0`) |
| Calico | `default via 169.254.1.1`: a made-up address the node answers for |
| Cilium | `default via <cilium_host IP>` |
| AWS VPC CNI | `default via 169.254.1.1`, pod IP from the VPC |

```sh
ip link show eth0
```

```text
3: eth0@if17: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UP mode DEFAULT
    link/ether aa:c3:2b:11:9e:40 brd ff:ff:ff:ff:ff:ff link-netnsid 0
```

**`mtu 1450`** is the largest packet the pod can send. Overlays need room
for their own headers, so pod MTUs are usually smaller than the node's (1500,
or 9001 on some clouds). See [ping](ping.md#find-an-mtu-problem) to test it.

## What a node looks like

With `kubectl debug node/<node>` you see the node's network. Interfaces you're
likely to meet:

| Interface | What it is |
| --- | --- |
| `eth0`, `ens5`, `enp0s3`... | The node's real network card |
| `veth...`, `cali...`, `lxc...`, `eni...` | Node-side ends of pod interfaces (one per pod) |
| `cni0`, `cbr0` | A bridge connecting pods on this node (bridge-based CNIs) |
| `flannel.1` | Flannel's VXLAN overlay |
| `vxlan.calico`, `tunl0` | Calico's VXLAN or IP-in-IP overlay |
| `cilium_host`, `cilium_net`, `cilium_vxlan`, `cilium_geneve` | Cilium's interfaces |
| `kube-ipvs0` | kube-proxy in IPVS mode: every ClusterIP is assigned here |
| `nodelocaldns` | NodeLocal DNSCache, usually `169.254.20.10` |

Routes on a node show how pod traffic reaches other nodes:

```text
default via 192.168.1.1 dev eth0
10.244.0.0/24 via 10.244.0.0 dev flannel.1 onlink     # Pods on node 1, through the overlay
10.244.1.0/24 dev cni0 proto kernel scope link src 10.244.1.1   # Pods on this node
10.244.2.0/24 via 10.244.2.0 dev flannel.1 onlink     # Pods on node 3, through the overlay
```

With Calico, routes to other nodes' pods are often marked `proto bird` (learned
over BGP), and each local pod has its own `/32` route to its `cali...`
interface.

## Recipes

### Which way does traffic to an address go?

```sh
ip route get 10.244.2.15
```

```text
10.244.2.15 via 10.244.1.1 dev eth0 src 10.244.1.5 uid 0
```

On a node this tells you whether a pod IP goes through the overlay, a bridge, or
straight out the main interface. If the answer surprises you, the route for
it is missing or wrong.

### Find a pod's interface on its node

Inside the pod, `eth0@if17` says the node-side end has index 17. On the node:

```sh
ip -o link | grep '^17:'
```

```text
17: cali8a1b2c3d4e5@if3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 ...
```

Now you can capture that pod's traffic on the node with
`tcpdump -i cali8a1b2c3d4e5`, or check its counters.

### Look for errors and drops

```sh
ip -s link show eth0
```

```text
    RX:  bytes packets errors dropped  missed   mcast
     812345   10233      0     152       0       0
    TX:  bytes packets errors dropped carrier collsns
     998877    9921      0       0       0       0
```

`errors` or `dropped` that keep growing while you watch mean packets are being
lost on this interface. On a pod's interface, drops often mean the pod
receives more than it can handle. On a node's interface, they can mean the
network card or its queues are overloaded.

### Neighbour problems

```sh
ip neigh
```

```text
10.244.1.1 dev eth0 lladdr 0a:58:0a:f4:01:01 REACHABLE
192.168.1.20 dev eth0 FAILED
```

`FAILED` or `INCOMPLETE` means the address got no answer to ARP. The host is
down, or it's not on the same network segment as you think.

### Several routing tables

Some CNIs (the AWS VPC CNI is one) send traffic from different pods through
different interfaces, using routing rules:

```sh
ip rule
ip route show table all | grep -v '^local\|^broadcast'
```

If a pod's traffic leaves through the wrong interface, check which rule
matches its IP.

### Run any command in a pod's network from the node

On a node, `nsenter` runs a command inside another process's network
namespace. Find the PID of a process in the pod (with
[crictl](crictl.md#find-a-containers-process), or see [procps](procps.md)),
then:

```sh
nsenter -t <pid> -n ip addr
nsenter -t <pid> -n ss -tlnp
nsenter -t <pid> -n tcpdump -i eth0 -nn
```

This lets you use all of kdbg's tools in a pod whose image doesn't have them,
without attaching a debug container to it. It needs the `sysadmin` profile.

## Pitfalls

- **Pods only see their own network.** To see the node's interfaces and
  routes, use `kubectl debug node/<node>`.
- **ClusterIPs don't appear anywhere** (except on `kube-ipvs0` in IPVS mode).
  They're handled by kube-proxy's rules, not routes. See
  [iptables](iptables.md) and [nft](nft.md).
- **Changes on a node are real and immediate.** Changing a route or an MTU
  on a node can cut it off from the cluster. Changes made by hand are also
  overwritten when the CNI or the node restarts.
- **Interface names are cut short.** Interface names are limited to 15
  characters, so long CNI names are shortened or hashed.

## Related

- [ss](ss.md), for sockets and connections (also from `iproute2`)
- [ping](ping.md) and [mtr](mtr.md), to test the routes you found
- [tcpdump](tcpdump.md), to capture on the interfaces you found

## Manuals

- [ip](https://manpages.debian.org/stable/iproute2/ip.8.en.html)
- [ip-route](https://manpages.debian.org/stable/iproute2/ip-route.8.en.html)
- [ip-link](https://manpages.debian.org/stable/iproute2/ip-link.8.en.html)
