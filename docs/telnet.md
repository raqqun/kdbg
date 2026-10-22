# telnet and other busybox extras

kdbg includes `busybox-extras`, a set of small network clients and servers from
busybox. The most used one is `telnet`, but a few of the others are handy
in a cluster too, especially `httpd` and `tcpsvd` as quick test servers.

## Privileges

None, except listening on ports below 1024, which kdbg can do as root in most
clusters.

## telnet

`telnet` connects to a TCP port and lets you type to it interactively. It was
made for the Telnet protocol, but it's mostly used today to talk by hand to
text protocols like HTTP, SMTP or Redis.

```sh
telnet my-svc 80
```

```text
Connected to my-svc
GET / HTTP/1.1
Host: my-svc

HTTP/1.1 200 OK
...
```

To get out, press `Ctrl+]`, then `e`. If the server closes the connection,
`telnet` exits by itself.

If the connection fails:

| Message | Meaning |
| --- | --- |
| `telnet: can't connect to remote host (...): Connection refused` | The host answered and refused. Nothing listens on that port. |
| Hangs, then `telnet: can't connect to remote host (...): Operation timed out` | No answer at all. Packets are dropped on the way. `telnet` has no timeout option, so this can take minutes. |
| `telnet: bad address 'my-svc'` | DNS failed. See [DNS tools](dns.md). |

See [nc](nc.md#reading-the-output) for what each of these can mean in a
cluster.

### telnet or nc?

They do mostly the same job. [nc](nc.md) is usually the better choice:

- `nc` can test a port without sending anything (`-z`), with a timeout (`-w`),
  and can take input from a pipe. `telnet` is only interactive.
- `telnet` interprets some bytes as Telnet commands, which garbles binary
  protocols. `nc` passes everything through unchanged.

`telnet` is handy because many people know it, and because it sends line
endings as `\r\n`, which SMTP and some other protocols require.

### Examples

**SMTP:**

```text
telnet mail.example.com 25
220 mail.example.com ESMTP
EHLO kdbg
250-mail.example.com
...
QUIT
```

**Redis:**

```text
telnet redis 6379
PING
+PONG
INFO server
...
```

## httpd: a quick web server

`httpd` serves files from a directory over HTTP. It's a fast way to put a
target in the cluster for testing NetworkPolicies, Ingress rules or load
balancers:

```sh
mkdir -p /tmp/www && echo "hello from $(hostname)" > /tmp/www/index.html
httpd -f -v -p 8080 -h /tmp/www
```

- `-f` keeps it in the foreground, so you see it and can stop it with Ctrl+C.
- `-v` logs every request, with the client's IP.
- `-p` sets the port (default 80). `-p 127.0.0.1:8080` listens only on
  localhost.
- `-h` sets the directory to serve.

Since each pod's page shows its own hostname, running it in several pods behind
a Service shows you which pod answered each request.

As a pod of its own:

```sh
kubectl run web-test --image=ghcr.io/raqqun/kdbg --port=8080 -- \
  sh -c 'mkdir -p /tmp/www && hostname > /tmp/www/index.html && httpd -f -v -p 8080 -h /tmp/www'
kubectl expose pod web-test --port=80 --target-port=8080
```

It can also serve a file you want to download into another pod: put the file in
the served directory and fetch it with `wget` or `curl`.

## tcpsvd: run a command for each connection

`tcpsvd` listens on a port and runs a command for each connection, with the
command's input and output connected to the client. It also logs every
connection:

```sh
tcpsvd -v 0.0.0.0 9000 cat     # An echo server
```

It puts the client's address in the `TCPREMOTEADDR` variable, which makes it
easy to build a server that tells clients where they come from:

```sh
tcpsvd -v 0.0.0.0 9000 sh -c 'echo "you came from $TCPREMOTEADDR"'
```

Connect to it with `nc <ip> 9000`. This shows whether the source IP of
traffic is kept or replaced on the way. Useful for checking SNAT, egress
gateways, or `externalTrafficPolicy` on a LoadBalancer or NodePort Service.

## Other tools

These are rarely needed for debugging but are there if you need them:

| Tool | What it is |
| --- | --- |
| `ftpget`, `ftpput` | Download or upload one file over FTP |
| `tftp` | TFTP client, for network boot setups |
| `ftpd`, `tftpd` | FTP and TFTP servers |
| `telnetd` | Telnet server |
| `inetd` | Starts servers on demand when a connection comes in |
| `udhcpd`, `dumpleases` | DHCP server and its lease list |
| `dnsd` | A tiny DNS server answering from a file |
| `fakeidentd` | An ident server that answers every query with the same name |
| `conspy` | Look at a Linux virtual console |

Run any of them with `--help` for its options.

## Related

- [nc](nc.md), for non-interactive connection tests
- [socat](socat.md), for relays and more flexible test servers

## Manual

- [BusyBox commands](https://busybox.net/downloads/BusyBox.html)
