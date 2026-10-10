# kdbg

A small container image for debugging Kubernetes clusters from the inside.

When something in a cluster can't reach something else (a service won't
resolve, a port won't answer, traffic is slow), you need a shell next to the
problem with the right tools in it. Application images rarely ship those tools.
kdbg is an Alpine image with common network troubleshooting tools and `kubectl`
already installed, so you can run it in the cluster and start investigating.

## What's inside

| Tool | What it gives you | Why it helps in a cluster |
| --- | --- | --- |
| `bash` | A comfortable shell | Tab completion and history while you poke around. |
| `curl`, `wget` | HTTP requests | Check whether a service answers and what it returns. |
| [`dig`, `nslookup`, `host`](docs/dns.md) | DNS lookups | Check that service names resolve, and to which IPs. Many "can't connect" problems are really DNS problems. |
| [`ping`](docs/ping.md) | Basic reachability | Quick first check that another pod or node can be reached. |
| [`mtr`](docs/mtr.md), [`tcptraceroute`](docs/tcptraceroute.md) | Network path tracing | Find where along the way traffic to a host gets lost or slows down. |
| [`nc`](docs/nc.md) (netcat), [`socat`](docs/socat.md) | Raw TCP/UDP connections | Test whether a port is open, or relay traffic between ports. |
| [`telnet` and other busybox extras](docs/telnet.md) | Manual protocol checks | Type commands at a service by hand. |
| [`iptraf-ng`](docs/iptraf-ng.md) | Live traffic monitor | Watch which connections are active on an interface. |
| [`tcpdump`](docs/tcpdump.md) | Packet capture | See whether traffic actually reaches a pod, and what it looks like. |
| [`ip`](docs/ip.md), [`ss`](docs/ss.md) | Network setup and sockets | `ip addr` and `ip route` show the pod's network setup. `ss -tlnp` lists open ports and connections. |
| [`openssl`](docs/openssl.md) | TLS inspection | `openssl s_client` shows a server's certificates, their expiry and chain, and which hostname is presented. Useful for ingress and webhook certificate problems. |
| `jq`, `yq` | JSON and YAML filtering | Pick out fields from `kubectl ... -o json` output and API responses. |
| [`iperf3`](docs/iperf3.md) | Bandwidth testing | Run it in two kdbg pods to measure network speed between them, for example across nodes. |
| [`nmap`](docs/nmap.md) | Port scanning | Find what's listening across a range of pods or services, and check that network policies block what they should. |
| [`strace`](docs/strace.md), [`lsof`](docs/lsof.md) | System calls and open files | With `kubectl debug --target`, see what another container's process is doing and which files and sockets it has open. |
| [`ps`, `top` (procps)](docs/procps.md) | Full process tools | More detailed process information than the busybox versions. |
| [`conntrack`](docs/conntrack.md), [`iptables`](docs/iptables.md), [`nft`](docs/nft.md) | Connection tracking and firewall rules | When debugging a node, see how kube-proxy routes service traffic and which connections it is tracking. |
| [`crictl`](docs/crictl.md) | Container runtime client | When debugging a node, list its pods and containers, read their logs and test image pulls straight from containerd or CRI-O, even when the API server or kubelet is unhealthy. |
| `kubectl` | The Kubernetes API | Query the cluster from inside it, as the pod's service account. |

Linked tools have a guide in [docs](docs/README.md) covering common
commands, how to read their output, and what to watch out for in a cluster.

Images are built for `linux/amd64` and `linux/arm64`.

## Usage

The image is published at `ghcr.io/raqqun/kdbg`.

### Start a throwaway debug pod

```sh
kubectl run kdbg -it --rm --restart=Never --image=ghcr.io/raqqun/kdbg -- bash
```

You get a shell in a new pod, in the same network as your workloads. The pod is
deleted when you exit.

Add `-n <namespace>` to start it in a specific namespace. This matters when
you're testing short DNS names like `my-service`, or network policies.

### Attach to a running pod

To debug a specific pod, add kdbg to it as an ephemeral container. It shares
the pod's network, so `localhost` is the pod's own `localhost`:

```sh
kubectl debug -it <pod> --image=ghcr.io/raqqun/kdbg --target=<container> -- bash
```

`--target` also lets you see the target container's processes.

### Debug a node

```sh
kubectl debug node/<node> -it --image=ghcr.io/raqqun/kdbg -- bash
```

This runs kdbg on the node with the host's network. The node's filesystem is
mounted at `/host`.

### Run it locally

```sh
podman run --rm -it ghcr.io/raqqun/kdbg bash
# or
docker run --rm -it ghcr.io/raqqun/kdbg bash
```

### Things to know

- **`kubectl` inside the pod** uses the pod's service account. It can only do
  what that account is allowed to do, which by default is very little.
- **Some tools need extra privileges.** `tcpdump` and `iptraf-ng`, and `ping` or
  `mtr` on some clusters, need the `NET_RAW` or `NET_ADMIN` capabilities. If they fail with a
  permission error, the cluster's security policy is probably blocking them.
- **Node tools only make sense on a node.** `conntrack`, `iptables` and `nft`
  show the network rules of wherever kdbg is running. Inside a normal pod that
  is the pod's own, mostly empty, network. Use them with
  `kubectl debug node/<node>` to see the node's rules. They also need the
  `NET_ADMIN` capability. `crictl` only works in `kubectl debug node/<node>`,
  where it finds the node's container runtime under `/host`.

## Image tags

Image versions follow `kubectl` versions. There is one image for each of the
three newest Kubernetes minor versions, so you can pick the one that matches
your cluster. `kubectl` is only guaranteed to work with clusters within one
minor version of itself.

| Tag | What it is | Example |
| --- | --- | --- |
| `<major>.<minor>` | The latest patch release of that minor version | `1.36` |
| `<major>.<minor>.<patch>` | That exact `kubectl` version | `1.36.5` |
| `latest` | The newest supported minor version | Same as `1.37` |

Each image has the newest `crictl` release for the same minor version. A new
Kubernetes minor version can come out before its `crictl` release, so until
it's published, the image has the previous minor version's `crictl`.

Images are rebuilt every week and on every change to this repository. New
`kubectl` patch releases and Alpine security updates are picked up
automatically. When a new Kubernetes minor version is released, it is added and
the oldest one stops being rebuilt. Its existing tags stay available but no
longer get updates.

Use an exact `<major>.<minor>.<patch>` tag if you need the `kubectl` version to
stay fixed. The image is still rebuilt weekly, so the Alpine packages in it can
change.

## Building it yourself

```sh
podman build -t kdbg .
```

To use a different `kubectl` or `crictl` version:

```sh
podman build --build-arg KUBECTL_VERSION=1.36.5 --build-arg CRICTL_VERSION=1.36.0 -t kdbg .
```

## License

MIT. See [LICENSE](LICENSE).
