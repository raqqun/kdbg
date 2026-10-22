# ss

`ss` lists sockets: which ports are listening, which connections are open, and
what state they're in. It replaces the older `netstat` and is faster.

## When to use it in a cluster

- Checking which ports a pod listens on, and on which address.
- Seeing who a pod is connected to.
- Spotting connection problems by state: many connections stuck opening,
  waiting to close, or piling up.
- Looking at TCP details like round-trip time and retransmissions for a
  connection.

To see a pod's sockets, attach kdbg to it with
`kubectl debug -it <pod> --target=<container>`. A separate kdbg pod only sees
its own sockets.

## Privileges

None for listing. Seeing which process owns a socket (`-p`) may need
`SYS_PTRACE` if the process runs as another user. Closing connections
(`-K`) needs `NET_ADMIN`.

## Common commands

```sh
ss -tlnp                 # Listening TCP ports, with the process
ss -ulnp                 # Listening UDP ports
ss -tanp                 # All TCP sockets, any state
ss -tn state established # Open TCP connections only
ss -s                    # Summary: counts per state
ss -tni                  # TCP connections with internal details (RTT, retransmits)
ss -tno                  # With timers (retransmit, keepalive)
ss -x                    # Unix sockets
ss -tn dst 10.244.2.15   # Connections to one IP
ss -tn '( dport = :5432 or sport = :5432 )'   # Connections involving port 5432
ss -tn state close-wait  # Connections in a given state
ss -H -tn state time-wait | wc -l              # Count sockets in a state (-H: no header)
```

| Option | What it does |
| --- | --- |
| `-t`, `-u`, `-x` | TCP, UDP, Unix sockets |
| `-l` | Listening sockets only |
| `-a` | All sockets, listening and not |
| `-n` | Show numbers, not names, for addresses and ports |
| `-p` | Show the process owning each socket |
| `-i` | TCP internals: RTT, congestion window, retransmits, bytes |
| `-o` | Timers |
| `-e` | Extra details: user ID, inode |
| `-m` | Memory used by each socket |
| `-s` | Summary |
| `-4`, `-6` | IPv4 or IPv6 only |
| `-H` | No header line |
| `-K` | Close the matching sockets |

## Reading the output

### Listening sockets

```sh
ss -tlnp
```

```text
State   Recv-Q  Send-Q   Local Address:Port   Peer Address:Port  Process
LISTEN  0       4096           0.0.0.0:8080        0.0.0.0:*      users:(("app",pid=1,fd=7))
LISTEN  0       128          127.0.0.1:9090        0.0.0.0:*      users:(("app",pid=1,fd=9))
LISTEN  0       4096                 *:8443              *:*      users:(("app",pid=1,fd=11))
```

The local address decides who can connect:

| Local address | Who can connect |
| --- | --- |
| `0.0.0.0:8080` | Anyone, over IPv4 |
| `*:8443` or `[::]:8443` | Anyone, usually over IPv4 and IPv6 |
| `127.0.0.1:9090` or `[::1]:9090` | Only processes inside the same pod |
| `10.244.1.5:8080` | Only connections to that specific address |

An application listening on `127.0.0.1` is the classic reason a Service can't
reach it while `curl localhost` inside the pod works.

On a listening socket, **`Send-Q`** is the maximum number of connections
waiting to be accepted, and **`Recv-Q`** is how many are waiting now. If
`Recv-Q` gets close to `Send-Q`, the application isn't accepting connections
fast enough, and new ones get dropped.

### Connections

```sh
ss -tanp
```

```text
State      Recv-Q  Send-Q   Local Address:Port    Peer Address:Port   Process
ESTAB      0       0           10.244.1.5:43210   10.244.2.15:5432    users:(("app",pid=1,fd=12))
SYN-SENT   0       1           10.244.1.5:51002   10.96.33.4:6379     users:(("app",pid=1,fd=14))
CLOSE-WAIT 1       0           10.244.1.5:8080    10.244.3.7:39122    users:(("app",pid=1,fd=15))
TIME-WAIT  0       0           10.244.1.5:44110   10.244.2.15:5432
```

On an open connection, **`Recv-Q`** is data received that the application
hasn't read yet, and **`Send-Q`** is data sent that the other side hasn't
acknowledged yet. Values that stay high mean the application is slow to read,
or the other side or the network is slow.

What the states tell you:

| State | Meaning | Many of them means |
| --- | --- | --- |
| `ESTAB` | Open connection | Normal. Compare with what you expect, for example the size of a connection pool. |
| `SYN-SENT` | Connecting, no answer yet | The destination is unreachable or drops traffic. Check with [nc](nc.md). |
| `SYN-RECV` | Someone is connecting to us, handshake not finished | The replies don't reach the client, or a SYN flood. |
| `CLOSE-WAIT` | The other side closed, the application hasn't | The application doesn't close its connections. A bug, often a leak. |
| `TIME-WAIT` | Closed, waiting a short while before the port can be reused | Many short connections. Thousands to the same destination can use up source ports. |
| `FIN-WAIT-2` | We closed, waiting for the other side | The other side doesn't close its end. |

### TCP internals

```sh
ss -tni dst 10.244.2.15
```

```text
ESTAB 0 0 10.244.1.5:43210 10.244.2.15:5432
     cubic wscale:7,7 rto:204 rtt:0.512/0.21 mss:1398 cwnd:10 bytes_sent:18234 bytes_received:99812 retrans:0/3 ...
```

- **`rtt:0.512/0.21`** is the round-trip time and its variation, in
  milliseconds.
- **`retrans:0/3`** is retransmissions: currently outstanding, and total. A
  growing total means packet loss on this connection.
- **`cwnd`** is the congestion window. Small values on a busy connection mean
  TCP is holding back after losses.
- **`mss:1398`** is the largest segment it sends, based on the MTU.

## Recipes

### What does this pod listen on?

```sh
kubectl debug -it <pod> --image=ghcr.io/raqqun/kdbg --target=<container> -- ss -tlnp
```

Compare with the Service's `targetPort` and the container's ports. A
Service pointing to a port nothing listens on refuses connections.

### Is the application leaking connections?

```sh
ss -s
ss -H -tn state close-wait | wc -l
ss -H -tn state established | awk '{print $4}' | sort | uniq -c | sort -rn | head
```

The last command counts open connections by remote address. Run them a few
minutes apart. Numbers that keep growing point to connections that are never
closed or never reused.

### Are connections being dropped at the listen queue?

```sh
nstat -az | grep -E 'ListenOverflows|ListenDrops'
```

`nstat` (also from `iproute2`) shows the kernel's network counters for the
current network namespace. Growing `ListenOverflows` means the application
doesn't accept connections fast enough. Clients see timeouts or slow connects.

Other useful counters:

```sh
nstat -az | grep -E 'TcpRetransSegs|TcpExtTCPTimeouts|TcpAttemptFails|TcpEstabResets'
```

### Close a stuck connection

```sh
ss -K dst 10.244.2.15 dport = :5432
```

This needs `NET_ADMIN`, and a kernel that allows it. The application sees the
connection fail, which can make it reconnect.

On nodes with SELinux enforcing (common on RHEL, Fedora and OpenShift), it can
fail with `SOCK_DESTROY answers: Permission denied` even with `NET_ADMIN`,
because SELinux blocks it for normal containers. It works from a privileged
container (`--profile=sysadmin`).

## Pitfalls

- **`ss` only sees the current network namespace.** In a separate kdbg pod you
  see kdbg's sockets, not the application's. On a node, you see the node's
  sockets and host-network pods, not regular pods. Use
  `kubectl debug --target` or `nsenter` (see [ip](ip.md#run-any-command-in-a-pods-network-from-the-node)).
- **The process column is empty** when kdbg can't see the process (no
  `--target`) or isn't allowed to read its details. Add `--profile=general`
  for `SYS_PTRACE`.
- **Filter syntax needs spaces and quotes.** `dport = :443` with spaces around
  `=`, and parentheses in quotes.

## Related

- [lsof](lsof.md), to see sockets together with all other open files of a
  process
- [nc](nc.md), to test the ports you found
- [ip](ip.md), for interfaces and routes
- [tcpdump](tcpdump.md), to see the traffic on a connection

## Manuals

- [ss](https://manpages.debian.org/stable/iproute2/ss.8.en.html)
- [nstat](https://manpages.debian.org/stable/iproute2/nstat.8.en.html)
