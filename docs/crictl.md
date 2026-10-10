# crictl

`crictl` talks to a node's container runtime (containerd or CRI-O) through
the Container Runtime Interface, the same API the kubelet uses. It shows the
pods, containers and images the runtime has on that node, and lets you read
their logs, run commands in them and pull images, without going through the
Kubernetes API.

kdbg's `crictl` comes from the cri-tools release matching its `kubectl` minor
version, and is set up for `kubectl debug node/`. See
[How kdbg sets it up](#how-kdbg-sets-it-up).

## When to use it in a cluster

- The API server or the kubelet is unhealthy, so `kubectl get pods` or
  `kubectl logs` doesn't help, but the containers still run on the node.
- A node is `NotReady` and you want the runtime's own view: is it up, and is
  the network plugin ready?
- A pod is stuck in `ContainerCreating` or `ImagePullBackOff`, and you want to
  test the image pull from the node itself.
- Reading the logs of a container that crashed, or of static pods like
  `kube-apiserver` and `etcd`.
- Finding the PID of a container's process, to use with [nsenter](ip.md#run-any-command-in-a-pods-network-from-the-node),
  [strace](strace.md) or [lsof](lsof.md).
- Checking a container's CPU and memory use as the runtime sees it.

## Privileges

`crictl` needs the runtime's socket, so it only works in a node debugging pod,
which mounts the node's filesystem at `/host`:

```sh
kubectl debug node/<node> -it --image=ghcr.io/raqqun/kdbg --profile=sysadmin -- bash
```

The socket belongs to `root`, which kdbg runs as, so on many nodes the
`general` profile is enough. On nodes with SELinux enforcing, a normal
container may not be allowed to connect to the socket. Use `--profile=sysadmin`
there.

Access to the runtime's socket gives full control of every container on the
node. Treat a node debugging pod as root on the node.

## How kdbg sets it up

`crictl` normally looks for the runtime's socket under `/run`. In a node
debugging pod the node's `/run` is at `/host/run`, so kdbg ships a
`/etc/crictl.yaml` that points to containerd's usual socket there:

```yaml
runtime-endpoint: unix:///host/run/containerd/containerd.sock
```

For another runtime or path, set `CONTAINER_RUNTIME_ENDPOINT`, or pass `-r` to
a single command:

```sh
export CONTAINER_RUNTIME_ENDPOINT=unix:///host/run/crio/crio.sock   # CRI-O
crictl -r unix:///host/run/k3s/containerd/containerd.sock ps         # k3s and RKE2
```

| Runtime | Socket in a node debugging pod |
| --- | --- |
| containerd | `/host/run/containerd/containerd.sock` (the default) |
| CRI-O | `/host/run/crio/crio.sock` |
| k3s, RKE2 (their own containerd) | `/host/run/k3s/containerd/containerd.sock` |
| cri-dockerd (Docker Engine) | `/host/run/cri-dockerd.sock` |

If none of these exist, ask the kubelet which one it uses:

```sh
grep -h containerRuntimeEndpoint /host/var/lib/kubelet/config.yaml
ps -eo args | grep -o -- '--container-runtime-endpoint=[^ ]*'
```

kdbg also links `/var/log/pods` to `/host/var/log/pods`. `crictl logs` reads
log files itself, from the path the runtime gives it, which is a path on the
node. Without the link it fails with
`lstat /var/log/pods: no such file or directory`.

Outside a node debugging pod there's no `/host`, and every command fails with
`dial unix /host/run/containerd/containerd.sock: connect: no such file or directory`.

## Common commands

```sh
crictl pods                          # Pods on this node
crictl pods --namespace my-namespace # Only one namespace (a regular expression)
crictl ps                            # Running containers
crictl ps -a                         # All containers, including exited ones
crictl ps -a --name my-app           # Containers whose name matches (a regular expression)
crictl ps -a --state exited          # Only exited containers
crictl ps -q --name my-app           # Only the IDs, for use in other commands
crictl inspect <container>           # Everything about a container, as JSON
crictl inspectp <pod>                # Everything about a pod sandbox, as JSON
crictl logs <container>              # A container's logs
crictl logs -f --tail 20 <container> # Follow, starting from the last 20 lines
crictl logs -p <container>           # The previous instance's logs, after a restart
crictl exec -it <container> sh       # Run a shell in a container
crictl stats                         # CPU and memory per container
crictl images                        # Images on this node
crictl pull <image>                  # Pull an image, as the node would
crictl info                          # Runtime status and configuration
crictl version                       # Runtime name and version
```

`<container>` and `<pod>` are IDs from `crictl ps` and `crictl pods`. A unique
prefix is enough, like the 13 characters shown in the tables.

## Reading the output

### Pods and containers

```sh
crictl ps -a
```

```text
CONTAINER       IMAGE                              CREATED          STATE    NAME     ATTEMPT  POD ID          POD                   NAMESPACE
d87651fc86ad6   docker.io/library/busybox:latest   2 minutes ago    Exited   migrate  3        c24b8f0f2db10   web-7d9c6b5f4-x2lqp   my-namespace
3660bc5698d81   docker.io/library/busybox:latest   20 minutes ago   Running  web      0        c24b8f0f2db10   web-7d9c6b5f4-x2lqp   my-namespace
```

- **`NAME`** is the container's name in the pod spec. **`POD`** and
  **`NAMESPACE`** are the Kubernetes pod it belongs to.
- **`ATTEMPT`** counts restarts. It matches the `RESTARTS` column in
  `kubectl get pods`.
- **`STATE`** is `Created`, `Running`, `Exited` or `Unknown`. A container
  that keeps restarting shows up as `Exited` most of the time.
- **Exited containers don't stay around.** The kubelet keeps the last exited
  instance of each container, so `kubectl logs --previous` works, and removes
  older ones.

Every pod also has a sandbox, the `pause` container that holds the pod's
network namespace. `crictl pods` lists sandboxes, `crictl ps` lists the
containers in them, and `crictl images` includes the `pause` image.

### Why did a container exit?

```sh
crictl inspect d87651fc86ad6 | jq '.status | {state, exitCode, reason, message, finishedAt, logPath}'
```

```json
{
  "state": "CONTAINER_EXITED",
  "exitCode": 1,
  "reason": "Error",
  "message": "",
  "finishedAt": "2026-10-10T14:59:06.392505996Z",
  "logPath": "/var/log/pods/my-namespace_web-7d9c6b5f4-x2lqp_0b6f1c9e-2a4d-4b8e-9f3a-1c2d3e4f5a6b/migrate/3.log"
}
```

| `exitCode`, `reason` | Meaning |
| --- | --- |
| `0`, `Completed` | The process exited normally |
| `1` (or another small number), `Error` | The application exited with an error. Its logs should say why. |
| `137`, `OOMKilled` | The container used more memory than its limit, and the kernel killed it |
| `137`, `Error` | Killed with `SIGKILL` for another reason, often after not stopping within its grace period |
| `139` | Segmentation fault |
| `143` | Stopped with `SIGTERM` |
| `126`, `127` | The command couldn't be run, or wasn't found in the image |

Exit codes above 128 are 128 plus the signal number.

### The runtime's health

```sh
crictl info | jq '.status.conditions'
```

```json
[
  { "type": "RuntimeReady", "status": true, "reason": "", "message": "" },
  { "type": "NetworkReady", "status": false, "reason": "NetworkPluginNotReady",
    "message": "Network plugin returns error: cni plugin not initialized" }
]
```

The kubelet marks the node `NotReady` when either condition is false.
`NetworkReady: false` with `cni plugin not initialized` means the runtime found
no working CNI configuration in `/etc/cni/net.d`. Usually the CNI's own pod
(Calico, Cilium, Flannel...) on that node isn't running yet, or failed. Look at
it with `crictl ps -a --name <cni-container>` and `crictl logs`.

## Recipes

### Logs when kubectl can't get them

```sh
crictl ps -a --name kube-apiserver
crictl logs --tail 50 <container>
```

This works for any container on the node, including static pods (the API
server, etcd, the scheduler) when the API server itself is down.

The files are also readable directly, under
`/host/var/log/pods/<namespace>_<pod>_<uid>/<container>/<attempt>.log`. Each
line has a timestamp, the stream and a flag before the message:

```text
2026-10-10T14:58:47.825914058Z stdout F connecting to db
2026-10-10T14:58:47.825925766Z stderr F error: connection refused
```

`F` means a full line, `P` a partial line continued in the next one. Older
files rotated by the kubelet sit next to the current one, as
`0.log.20261010-145900` or `.gz`.

### ImagePullBackOff: test the pull from the node

```sh
crictl pull registry.example.com/team/app:1.4.2
```

The node pulls the way the kubelet would, with the runtime's registry mirrors,
certificates and proxy settings. The error is usually more precise than the
pod's events:

| Error contains | Meaning |
| --- | --- |
| `not found` | The tag or digest doesn't exist |
| `pull access denied`, `authorization failed`, `401 Unauthorized` | The registry wants credentials, or doesn't have the repository |
| `x509: certificate signed by unknown authority` | The node doesn't trust the registry's certificate |
| `dial tcp ...: i/o timeout`, `no such host` | The node can't reach the registry, or can't resolve its name |
| `toomanyrequests` | Rate limited by the registry |

`crictl pull` doesn't use the pod's `imagePullSecrets`. For a private
registry, pass credentials with `--creds user:password`. Remember they end up
in the shell history.

### Find a container's process

```sh
crictl inspect --output go-template --template '{{.info.pid}}' <container>
```

This prints the PID of the container's main process, as seen from the node.
kdbg's node debugging pod shares the node's processes, so you can use it right
away:

```sh
PID=$(crictl inspect -o go-template --template '{{.info.pid}}' $(crictl ps -q --name my-app))
nsenter -t $PID -n ss -tlnp      # Sockets in the pod's network
strace -f -p $PID                # System calls of the main process
ls -l /proc/$PID/root/etc/       # The container's filesystem
```

### A pod's IP and network namespace

```sh
crictl inspectp <pod> | jq '.status.network.ip, .status.linux.namespaces.options'
```

Pods with `hostNetwork: true` have no IP of their own here, and show
`"network": "NODE"`.

### Which containers use the most CPU or memory?

```sh
crictl stats
```

```text
CONTAINER       NAME     CPU %   MEM       DISK   INODES   SWAP
3660bc5698d81   web      0.00    913.4kB   0B     7        0B
```

`MEM` is the container's working set, the number the kubelet compares with
the memory limit and uses for eviction.

### Does the node have the image, and which version?

```sh
crictl images | grep my-app
crictl images --digests | grep my-app
```

Compare the digest with the registry's when you suspect a node runs an
outdated copy of a mutable tag like `latest`. `crictl imagefsinfo` shows how
much disk the images use.

## Pitfalls

- **Don't manage pods with `crictl`.** `crictl stop`, `rm`, `stopp` and
  `rmp` act behind the kubelet's back. The kubelet notices and recreates or
  cleans up after them, and the API doesn't know what happened. Use them only
  to unblock something that's stuck, and prefer `kubectl delete pod`.
- **`crictl rmi --prune` removes every image no container is using.** It frees
  disk, but every pod scheduled there afterwards pulls its images again.
- **Wrong socket, misleading error.** If kdbg's default path doesn't exist on
  this node, every command fails with `connect: no such file or directory`.
  See [How kdbg sets it up](#how-kdbg-sets-it-up).
- **`crictl exec` and `attach` go through the runtime's streaming server**,
  which listens on the node's `localhost`. That works in a node debugging pod,
  which uses the node's network. They fail on an exited container with
  `container is in CONTAINER_EXITED state`.
- **`-it` needs a terminal.** `crictl exec -it` fails with
  `input is not a terminal` when kdbg wasn't started with `-it`.
- **Only this node.** `crictl` sees the containers of the node it runs on,
  nothing else.

## Related

- [ip](ip.md#run-any-command-in-a-pods-network-from-the-node), for `nsenter`
  into a container's network
- [strace](strace.md) and [lsof](lsof.md), once you have a container's PID
- [procps](procps.md), for the processes and memory of the whole node

## Manuals

- [crictl](https://github.com/kubernetes-sigs/cri-tools/blob/master/docs/crictl.md)
- [Debugging Kubernetes nodes with crictl](https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/)
