# kdbg tool guides

These guides explain how to use the troubleshooting tools in kdbg to debug
problems in a Kubernetes cluster. Each one covers what the tool is for, the
commands you'll use most, how to read their output, and what tends to go wrong.

`bash`, `curl`, `wget`, `jq`, `yq` and `kubectl` aren't covered here. They are
widely used and already have good documentation of their own.

## Pick a tool by problem

| Problem | Start with |
| --- | --- |
| A service name doesn't resolve, or resolves to the wrong thing | [DNS tools](dns.md) |
| A connection to a port fails or hangs | [nc](nc.md), then [nmap](nmap.md) or [tcptraceroute](tcptraceroute.md) |
| Another pod or node can't be reached at all | [ping](ping.md), [ip](ip.md), [mtr](mtr.md) |
| Traffic is slow, or some packets get lost | [mtr](mtr.md), [iperf3](iperf3.md), [ping](ping.md) |
| You need to know whether traffic actually reaches a pod | [tcpdump](tcpdump.md), [iptraf-ng](iptraf-ng.md) |
| TLS errors, wrong or expired certificates | [openssl](openssl.md) |
| What ports is this pod listening on, what is it connected to? | [ss](ss.md), [lsof](lsof.md) |
| A process hangs, crashes or misbehaves | [strace](strace.md), [procps](procps.md), [lsof](lsof.md) |
| A node is `NotReady`, or kubectl can't show a pod's containers or logs | [crictl](crictl.md) |
| How does a Service get routed to its pods on this node? | [iptables](iptables.md), [nft](nft.md), [conntrack](conntrack.md) |
| You want to type a protocol by hand | [nc](nc.md), [telnet](telnet.md) |
| You need to forward or relay a port, or watch the traffic going through it | [socat](socat.md) |
| Network policies: does traffic get blocked where it should? | [nc](nc.md), [nmap](nmap.md) |

## All guides

**Names and reachability**

- [dig, nslookup, host](dns.md): DNS lookups
- [ping](ping.md): basic reachability, latency and MTU checks
- [mtr](mtr.md): path tracing with live loss and latency per hop
- [tcptraceroute](tcptraceroute.md): path tracing with TCP packets, to a specific port

**Connections**

- [nc](nc.md): open TCP and UDP connections, test ports, listen
- [socat](socat.md): relay and forward traffic between almost anything
- [telnet and other busybox extras](telnet.md): manual protocol checks, a quick web server
- [nmap](nmap.md): port scanning across pods and services
- [openssl](openssl.md): TLS connections and certificates

**Watching traffic**

- [tcpdump](tcpdump.md): packet capture
- [iptraf-ng](iptraf-ng.md): live traffic monitor
- [iperf3](iperf3.md): bandwidth measurement

**Network setup**

- [ip](ip.md): interfaces, addresses, routes, neighbours
- [ss](ss.md): sockets, open ports and connections

**Processes**

- [strace](strace.md): system calls of a running process
- [lsof](lsof.md): open files and sockets
- [procps (ps, top and friends)](procps.md): process and memory information

**Node networking**

- [iptables](iptables.md): kube-proxy's iptables rules
- [nft](nft.md): nftables rules, including kube-proxy's nftables mode
- [conntrack](conntrack.md): connection tracking table

**Node runtime**

- [crictl](crictl.md): pods, containers, logs and images, straight from the
  container runtime

## Before you start

### Where kdbg runs decides what you see

The same command gives different answers depending on how you started kdbg.

| How you started kdbg | Network you see | Processes you see |
| --- | --- | --- |
| `kubectl run kdbg ...` | kdbg's own pod network: its own IP, its own `eth0` | Only kdbg's own |
| `kubectl debug -it <pod> --target=<container> ...` | The target pod's network: its IP, its `localhost`, its open ports | The target container's processes |
| `kubectl debug node/<node> ...` | The node's network: all its interfaces, routes and firewall rules | All processes on the node. The node's filesystem is at `/host`. |

A rough rule: to test the cluster network *from the outside of a workload*, use
`kubectl run`. To see what *a specific pod* sees, use `kubectl debug <pod>`. To
see how the node routes traffic, use `kubectl debug node/<node>`.

### Privileges

Many tools here need Linux capabilities that pods don't get by default:

| Capability | Needed by |
| --- | --- |
| `NET_RAW` | `tcpdump`, `iptraf-ng`, `mtr`, `tcptraceroute`, nmap's default SYN scan, UDP scan and OS detection, and `ping` on some clusters |
| `NET_ADMIN` | `iptables`, `nft`, `conntrack`, `ss -K`, changing anything with `ip` |
| `SYS_PTRACE` | `strace`, and `lsof` or `ps` details for processes owned by another user |

To check which ones you have, run this inside kdbg:

```sh
cap=$(awk '/^CapEff/{print $2}' /proc/self/status)
for b in 12:NET_ADMIN 13:NET_RAW 19:SYS_PTRACE; do
  (( 0x$cap >> ${b%%:*} & 1 )) && echo "${b#*:}: yes" || echo "${b#*:}: no"
done
```

**With `kubectl debug`**, pick a profile with `--profile`. Pass it explicitly,
because the default has changed between `kubectl` versions:

| Profile | What it adds |
| --- | --- |
| `general` | `SYS_PTRACE`. Good for `strace` and `lsof` on a target container. |
| `netadmin` | `NET_ADMIN` and `NET_RAW`. Good for `tcpdump`, `iptables`, `conntrack`. |
| `sysadmin` | Runs fully privileged. Everything works. |

```sh
kubectl debug -it <pod> --image=ghcr.io/raqqun/kdbg --target=<container> --profile=netadmin -- bash
kubectl debug node/<node> -it --image=ghcr.io/raqqun/kdbg --profile=sysadmin -- bash
```

Newer `kubectl` versions also accept `--custom=<file>` with a partial container
spec, if you need a combination that no profile gives you, for example
`{"securityContext":{"capabilities":{"add":["NET_RAW","SYS_PTRACE"]}}}`.

**With `kubectl run`**, add capabilities with `--overrides`. The override
replaces the whole container list, so it has to repeat the name, image and
terminal settings:

```sh
kubectl run kdbg -it --rm --restart=Never --image=ghcr.io/raqqun/kdbg --overrides='
{
  "spec": {
    "containers": [{
      "name": "kdbg",
      "image": "ghcr.io/raqqun/kdbg",
      "args": ["bash"],
      "stdin": true,
      "tty": true,
      "securityContext": {"capabilities": {"add": ["NET_ADMIN", "NET_RAW"]}}
    }]
  }
}'
```

Add `"nodeName": "<node>"` next to `"containers"` to run the pod on a specific
node. Several guides use this to compare traffic on the same node and across
nodes.

**Pod Security Admission** may refuse these pods. A namespace at the
`restricted` or `baseline` level rejects added capabilities like `NET_ADMIN`,
and node debugging pods need the `privileged` level. If `kubectl` reports a
`violates PodSecurity` error, use a namespace where debugging is allowed, or ask
whoever runs the cluster.

### Getting files out

Some tools write files you'll want to open on your own machine, like packet
captures or `strace` logs. Write them to `/tmp` and copy them with `kubectl cp`:

```sh
kubectl cp <namespace>/<pod>:/tmp/capture.pcap ./capture.pcap -c <container>
```

For an ephemeral container started with `kubectl debug`, `<container>` is the
name `kubectl debug` printed when it started (for example `debugger-abc12`).

You can also stream output straight to your machine, without a file in the pod:

```sh
kubectl exec <pod> -c <container> -- tcpdump -i any -U -w - > capture.pcap
```

### Help and manuals

The image doesn't include man pages, to stay small. Every tool has a `--help`
or `-h` option, and the full manuals are online. Each guide links to its
tool's manual.

### Placeholders

Commands in these guides use `<pod>`, `<namespace>`, `<node>` and similar
placeholders, and example names like `my-svc` and `my-namespace`. Replace them
with your own.
