# socat

`socat` connects two endpoints and copies data between them in both
directions. An endpoint can be almost anything: a TCP or UDP port, a listening
socket, a Unix socket, a TLS connection, a file, a program, or your terminal.
That makes it the tool for forwarding ports, relaying traffic, and watching
what passes through.

```text
socat [options] <address 1> <address 2>
```

## When to use it in a cluster

- Reaching something only the cluster can reach (a database in a private
  network, a pod's admin port) from your own machine, together with
  `kubectl port-forward`.
- Exposing a port that an application only opened on `127.0.0.1`.
- Sitting between a client and a server to see exactly what they send each
  other.
- Talking to a Unix socket.
- Quick test servers: echo, a fixed HTTP response, a UDP responder.

## Privileges

None, except for listening on ports below 1024, which kdbg can do as root in
most clusters.

## Addresses

| Address | What it is |
| --- | --- |
| `-` or `STDIO` | Your terminal |
| `TCP:host:port` | Connect to a TCP port |
| `TCP-LISTEN:port` | Listen on a TCP port |
| `UDP:host:port` | Send to a UDP port |
| `UDP-LISTEN:port` | Listen on a UDP port |
| `UNIX-CONNECT:/path` | Connect to a Unix socket |
| `UNIX-LISTEN:/path` | Create and listen on a Unix socket |
| `OPENSSL:host:port` | Connect with TLS |
| `OPENSSL-LISTEN:port` | Listen and accept TLS |
| `EXEC:command` | Run a program and talk to its input and output |
| `SYSTEM:'shell command'` | Same, through a shell |

Options are added after the address, separated by commas:

| Option | What it does |
| --- | --- |
| `fork` | On a listening address: handle each connection in a new process, and keep listening. Without it, socat exits after the first connection. |
| `reuseaddr` | Allow listening again on a port that was just used. Add it to every `*-LISTEN`. |
| `bind=ADDR` | Listen on, or connect from, a specific local address |
| `range=10.0.0.0/8` | Only accept connections from these addresses |
| `verify=0` | On `OPENSSL`: don't check the certificate |
| `cafile=FILE` | On `OPENSSL`: check the certificate against this CA |
| `cert=FILE`, `key=FILE` | On `OPENSSL`: certificate and key to present |
| `snihost=NAME` | On `OPENSSL`: name to send for SNI |
| `connect-timeout=N` | Give up connecting after N seconds |

Command-line options before the addresses:

| Option | What it does |
| --- | --- |
| `-v` | Print all data passing through to stderr, as text, marked `>` and `<` by direction |
| `-x` | Same, as hex. Use it for binary protocols. |
| `-d -d` | Log what socat does: connections, errors |
| `-T N` | Close after N seconds without traffic |

## Recipes

### Reach a cluster-internal service from your machine

`kubectl port-forward` only forwards to pods and Services. To reach something
only the cluster can reach, like a database in a private network, put socat in
the middle.

Start kdbg as a relay:

```sh
kubectl run relay --image=ghcr.io/raqqun/kdbg -- \
  socat TCP-LISTEN:5432,fork,reuseaddr TCP:db.internal.example.com:5432
```

Forward to it from your machine, and connect to `localhost:5432`:

```sh
kubectl port-forward pod/relay 5432:5432
psql -h localhost -p 5432 ...
```

Delete the pod when you're done. While it runs, anyone who can reach the pod
can reach the database through it.

### Expose a port the application only opens on localhost

Some applications bind admin or metrics ports to `127.0.0.1`, so they can't be
reached from outside the pod. Attach kdbg to the pod and relay a new port to
it:

```sh
kubectl debug -it <pod> --image=ghcr.io/raqqun/kdbg --target=<container> -- \
  socat TCP-LISTEN:19090,fork,reuseaddr TCP:127.0.0.1:9090
```

Now `<pod-ip>:19090` reaches the application's `127.0.0.1:9090`, as long as no
NetworkPolicy blocks it. It stops when you end the debug session.

### See what a client and server send each other

Put socat between them with `-v`. It prints everything that passes through:

```sh
socat -v TCP-LISTEN:8080,fork,reuseaddr TCP:my-svc:80
```

Point the client at kdbg's port 8080 instead of `my-svc:80`. The output shows
each chunk of data with its direction and timing:

```text
> 2026/10/10 11:52:03.118220  length=78 from=0 to=77
GET /api/v1/items HTTP/1.1\r
Host: my-svc\r
Accept: */*\r
\r
< 2026/10/10 11:52:03.124951  length=112 from=0 to=111
HTTP/1.1 401 Unauthorized\r
...
```

This works for any protocol that isn't encrypted. Use `-x` for binary
protocols.

### Talk to a Unix socket

```sh
socat - UNIX-CONNECT:/run/app/admin.sock
```

With `kubectl debug --target`, the target container's files are not at their
usual paths, but you can reach them through its process. Find the process ID
with `ps` (see [procps](procps.md)), then:

```sh
socat - UNIX-CONNECT:/proc/<pid>/root/run/app/admin.sock
```

Reading another container's files this way may need `SYS_PTRACE` (see
[Privileges](README.md#privileges)).

### Forward UDP

```sh
socat UDP-LISTEN:5353,fork,reuseaddr UDP:10.96.0.10:53
```

Queries sent to kdbg's port 5353 go to the cluster DNS service.

### Quick test servers

An echo server, that sends back whatever it receives:

```sh
socat TCP-LISTEN:8080,fork,reuseaddr EXEC:cat
```

A server that answers every request with the same HTTP response:

```sh
socat TCP-LISTEN:8080,fork,reuseaddr \
  SYSTEM:'printf "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n"'
```

A server that prints where each connection comes from:

```sh
socat -d -d TCP-LISTEN:8080,fork,reuseaddr EXEC:cat 2>&1 | grep 'accepting connection'
```

This is useful to check which source IP traffic arrives with, for example
whether a LoadBalancer Service with `externalTrafficPolicy: Local` keeps the
client's IP.

### TLS

Connect with TLS and type by hand:

```sh
socat - OPENSSL:my-svc:443,cafile=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
socat - OPENSSL:my-svc:443,verify=0     # Don't check the certificate
```

Add TLS in front of a plain-text service, for testing clients that require
TLS:

```sh
socat OPENSSL-LISTEN:8443,cert=server.pem,key=server.key,verify=0,fork,reuseaddr TCP:127.0.0.1:8080
```

[openssl](openssl.md) shows how to create a test certificate.

## Pitfalls

- **Without `fork`, socat exits after one connection.** Add `fork` to every
  listening address you want to keep using.
- **Without `reuseaddr`, restarting fails** with `Address in use` for a minute
  or so after the previous run.
- **socat checks TLS certificates by default.** Connecting with `OPENSSL:` to
  a server with a private CA fails until you pass `cafile=` or `verify=0`.
- **`-v` output on binary data is unreadable.** Use `-x`.
- **A relay changes the source IP.** The server sees connections from the
  socat pod, not from the original client. Keep that in mind when testing
  NetworkPolicies or IP allow-lists through a relay.
- **The relay is open to anyone who can reach it.** Use `range=` to restrict
  who can connect, and delete relay pods when you're done.

## Related

- [nc](nc.md), for simpler connection tests
- [openssl](openssl.md), for TLS details and certificates
- [tcpdump](tcpdump.md), to see traffic without putting anything in the middle

## Manual

- [socat](http://www.dest-unreach.org/socat/doc/socat.html)
