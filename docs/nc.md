# nc (netcat)

`nc` opens a TCP or UDP connection and connects it to your terminal: whatever
you type is sent, whatever comes back is printed. It can also listen on a port
and wait for someone to connect. That makes it the simplest way to answer "can
I connect to this port?", and a handy tool for speaking a protocol by hand.

kdbg has the OpenBSD version of `nc`. Other versions (busybox, nmap's `ncat`,
"traditional" netcat) take slightly different options, so commands copied
from elsewhere may need adjusting. In particular, this version has no `-e`
option to run a program.

## When to use it in a cluster

- Checking whether a Service, a pod or an external host accepts connections on
  a port.
- Telling apart the different ways a connection fails: refused, timed out, no
  route.
- Testing NetworkPolicies: listen in one pod, connect from another.
- Sending a request by hand (HTTP, Redis, SMTP) to see the raw response.

## Privileges

None.

## Common commands

```sh
nc -zv my-svc 80                    # Can I connect? (-z: connect and close at once, -v: say what happened)
nc -zv -w 3 my-svc 80               # Same, but give up after 3 seconds
nc -zv my-svc 8000-8010             # Try a range of ports
nc -zv my-svc 80 443 8080           # Try several ports
nc -zvn 10.244.2.15 80              # Skip DNS lookups
nc my-svc 6379                      # Connect and type by hand. Ctrl+C or Ctrl+D to stop.
nc -l 8080                          # Listen on port 8080 for one connection
nc -lk 8080                         # Listen, and keep listening after each connection closes
nc -lu 9999                         # Listen on UDP
nc -u my-svc 9999                   # Send UDP: what you type goes out as datagrams
nc -N my-svc 80 < request.txt       # Send a file, close the sending side when done
nc -C my-svc 25                     # Send CRLF line endings (needed by SMTP and some others)
nc -X connect -x proxy:3128 example.com 443   # Connect through an HTTP proxy
nc -U /path/to/app.sock             # Connect to a Unix socket
```

| Option | What it does |
| --- | --- |
| `-z` | Only check if the port accepts a connection. Send nothing. |
| `-v` | Report success or failure. Add it whenever you test connectivity. |
| `-w N` | Timeout in seconds for connecting and for idle connections |
| `-n` | No DNS lookups |
| `-u` | UDP instead of TCP |
| `-l` | Listen instead of connecting |
| `-k` | With `-l`: keep listening for more connections |
| `-N` | Close the sending side of the connection when the input ends. Many servers wait for this before answering. |
| `-q N` | After the input ends, wait N seconds, then quit |
| `-C` | Send CRLF line endings |
| `-s ADDR` | Source address to connect from |
| `-p PORT` | Source port to connect from |
| `-4`, `-6` | Force IPv4 or IPv6 |

## Reading the output

| Message | Meaning |
| --- | --- |
| `Connection to my-svc (10.96.142.17) 80 port [tcp/http] succeeded!` | Something accepted the connection. |
| `connect to ... failed: Connection refused` | The host answered and said no. Nothing listens on that port, or the application listens only on `127.0.0.1` inside its pod. For a Service, it can also mean the Service has no ready pods: kube-proxy rejects connections to Services without endpoints. |
| `connect to ... timed out: Operation in progress` (with `-w`), or `failed: Operation timed out` | No answer at all. Packets were dropped: a NetworkPolicy, a cloud firewall, a dead node, or a wrong IP. |
| `connect to ... failed: No route to host` | A router or the local network said the target can't be reached. The pod might be gone, or a firewall rejects with an ICMP message. |
| `getaddrinfo for host "my-svc" port 80: Name does not resolve` | DNS failed. See [DNS tools](dns.md). |

**Refused versus timed out** is the most useful distinction. Refused means the
network works and the problem is at the destination. Timed out means something
in between is dropping traffic.

## Recipes

### Test a Service and each pod behind it

A Service forwards each connection to one of its pods. If only some
connections fail, one pod may be the problem. Test the Service, then each pod
directly. Get the pod IPs and port from your own machine:

```sh
kubectl get endpointslices -n my-namespace -l kubernetes.io/service-name=my-svc \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'
```

Then in kdbg:

```sh
nc -zv -w 3 my-svc.my-namespace 80
for ip in 10.244.1.12 10.244.2.31 10.244.3.8; do nc -zvn -w 3 $ip 8080; done
```

Use the pod's container port (`targetPort`) for pod IPs, and the Service port
for the Service.

### Test a NetworkPolicy

Start a listener in a pod that has the labels the policy selects:

```sh
kubectl run np-target -n my-namespace --labels=app=my-app \
  --image=ghcr.io/raqqun/kdbg -- nc -lk 8080
kubectl get pod np-target -n my-namespace -o wide     # Note the pod IP
```

Then connect from a client pod with the labels you want to test, in the
namespace you want to test:

```sh
kubectl run np-client -n other-namespace --labels=app=frontend -it --rm \
  --restart=Never --image=ghcr.io/raqqun/kdbg -- nc -zv -w 3 <target-ip> 8080
```

`succeeded` means the policy allows it. A timeout means it blocks it. Policies
usually drop packets rather than refuse them, so blocked connections time out.
Delete the target pod when you're done.

### Send an HTTP request by hand

```sh
printf 'GET /healthz HTTP/1.1\r\nHost: my-svc\r\nConnection: close\r\n\r\n' | nc -N my-svc 80
```

You see the exact bytes the server sends back, headers included, with nothing
interpreted by a client library.

### Talk to Redis, memcached and other text protocols

```sh
printf 'PING\r\n' | nc -N -w 2 redis 6379          # Expect +PONG
printf 'stats\r\nquit\r\n' | nc -w 2 memcached 11211
```

### Check the service banner

Some protocols announce themselves when you connect. That confirms you're
talking to the right thing:

```sh
nc -w 3 my-sftp 22       # SSH-2.0-OpenSSH_...
nc -w 3 -C mail 25       # 220 mail.example.com ESMTP ...
```

### Test from inside a pod's own network

With `kubectl debug --target`, kdbg shares the pod's network. `localhost` is
the pod's own:

```sh
nc -zv localhost 8080
```

If this works but connecting to the pod's IP from elsewhere is refused, the
application listens only on `127.0.0.1`. Check with
`ss -tlnp` (see [ss](ss.md)).

### Copy a file between pods

```sh
nc -l 9000 > received.tar                  # In the receiving pod
tar cf - /some/dir | nc -N <receiver-ip> 9000  # In the sending pod
```

### Test through an HTTP proxy

If egress goes through a proxy, check that the proxy lets you through:

```sh
nc -zv -X connect -x proxy.internal:3128 api.example.com 443
```

## Pitfalls

- **UDP tests are unreliable.** UDP has no handshake, so `nc -zu` reports
  success unless the target sends back an ICMP "port unreachable", which most
  firewalls drop. To really test UDP, send something the server answers to
  and see if a reply comes back, or listen on the other side with `nc -lu`.
- **Without `-w`, a dropped connection hangs** for a long time (often more
  than a minute). Always pass a timeout when testing.
- **Without `-N`, some servers never answer.** They wait for the client to
  finish sending. If a piped request gets no reply, add `-N`.
- **A port that accepts connections isn't necessarily healthy.** The kernel
  accepts TCP connections as long as something listens, even if the
  application behind it is stuck. Send a real request to be sure.
- **Commands from other netcat versions don't always work.** `nc -l -p 8080`
  (traditional syntax) and `nc -e` are not supported. Use `nc -l 8080`, and
  [socat](socat.md) to run programs on connections.

## Related

- [socat](socat.md), for relaying, forwarding, TLS and Unix sockets
- [telnet](telnet.md), for interactive sessions, and a quick web server
- [nmap](nmap.md), to check many ports or hosts at once
- [openssl](openssl.md), for TLS connections
- [ss](ss.md), to see what's listening on the other side

## Manual

- [nc (OpenBSD)](https://man.openbsd.org/nc.1)
