# nmap

`nmap` checks many ports on many hosts at once and reports which ones are open,
closed or filtered. Where [nc](nc.md) answers "can I connect to this one
port?", `nmap` answers "what can I reach, and what is listening, across this
whole range?"

**Only scan what you're allowed to scan.** Scanning can set off security
alerts, and many organisations have rules about it. Keep scans as narrow as
the question you're answering.

## When to use it in a cluster

- Checking that NetworkPolicies block what they should and allow what they
  should, across many ports at once.
- Finding which pods or nodes have a given port open.
- Finding out what a pod or node exposes.
- Identifying an unknown service on a port.

## Privileges

nmap's default scan (SYN scan), UDP scans and OS detection need `NET_RAW`.
Without it, nmap fails with `Couldn't open a raw socket`. Add
`--unprivileged` to every command, which switches to a normal TCP connect
scan. That works for TCP port checks, just a bit slower.

See [Privileges](README.md#privileges).

## What's not included

nmap's script engine (NSE) scripts aren't installed, to keep the image small.
`-sC`, `--script` and `-A` (which includes scripts) fail with
`NSE: failed to initialize the script engine`. Port scans, service version
detection (`-sV`) and OS detection (`-O`) work.

## Common commands

```sh
nmap -Pn -p 80,443 my-svc                    # Check two ports
nmap -Pn -p 1-1024 10.244.2.15               # A range of ports
nmap -Pn -p- 10.244.2.15                     # All 65535 ports
nmap -Pn --top-ports 100 10.244.2.15         # The 100 most common ports
nmap -Pn -p 8080 --open 10.244.0.0/16        # Which pods in the pod network have 8080 open?
nmap -Pn -p 443 --reason my-svc              # Say why each port got its state
nmap -Pn -sV -p 8080 10.244.2.15             # What service and version runs on 8080?
nmap -sn 10.244.2.0/24                       # Which hosts answer at all? (no port scan)
nmap -Pn -sU -p 53 10.96.0.10                # UDP port 53
nmap -Pn -p 80 -iL targets.txt               # Scan hosts listed in a file, one per line
nmap --unprivileged -Pn -p 80,443 my-svc     # Without NET_RAW
```

| Option | What it does |
| --- | --- |
| `-Pn` | Skip the "is the host up?" check and scan anyway. Use it almost always in a cluster. |
| `-p` | Ports: `80`, `80,443`, `1-1024`, `-` for all. Prefix with `U:` or `T:` to mix UDP and TCP. |
| `--top-ports N` | The N most common ports |
| `-F` | Fast: the 100 most common ports |
| `--open` | Only show open ports |
| `--reason` | Show what reply decided each port's state |
| `-sT` | TCP connect scan: opens full connections. No privileges needed. |
| `-sS` | SYN scan: the default with `NET_RAW`. Faster, never completes the connection. |
| `-sU` | UDP scan. Slow, and needs `NET_RAW`. |
| `-sV` | Detect the service and version on open ports |
| `-O` | Guess the operating system. Needs `NET_RAW`. |
| `-sn` | Only find which hosts are up, no port scan |
| `-n` | No DNS lookups |
| `-T4` | Faster timing. Fine inside a cluster network. |
| `--max-retries N`, `--host-timeout 30s` | Limit how long it spends on unresponsive targets |
| `-oN FILE`, `-oG FILE`, `-oX FILE` | Save results as text, greppable lines, or XML |

## Reading the output

```text
Nmap scan report for my-svc.my-namespace.svc.cluster.local (10.96.142.17)
Host is up, received user-set (0.00042s latency).

PORT     STATE    SERVICE    REASON
80/tcp   open     http       syn-ack ttl 63
443/tcp  closed   https      reset ttl 63
8080/tcp filtered http-proxy no-response
```

| State | Meaning |
| --- | --- |
| `open` | Something accepts connections on this port. |
| `closed` | The host answered with a reset: it's reachable, but nothing listens on this port. |
| `filtered` | No answer, or an ICMP "unreachable" message. Something drops or rejects the traffic: usually a NetworkPolicy or a firewall. |
| `open\|filtered` | nmap can't tell. Common for UDP, which often gets no answer whether the port is open or not. |
| `unfiltered` | Only from ACK scans (`-sA`): reachable, but nmap can't tell if it's open. |

The `SERVICE` column is only a guess from the port number, unless you use
`-sV`. Port 8080 being called `http-proxy` doesn't mean it is one.

**For NetworkPolicies, the difference between `closed` and `filtered` is the
answer you're looking for.** `closed` means the traffic got through to the
pod. `filtered` means something dropped it on the way.

## Recipes

### Check a NetworkPolicy across many ports

Run kdbg with the labels and in the namespace of the client you want to test,
then scan the target pod:

```sh
kubectl run np-client -n frontend --labels=app=web -it --rm --restart=Never \
  --image=ghcr.io/raqqun/kdbg -- nmap -Pn --unprivileged -p 1-10000 --reason <target-pod-ip>
```

Ports the policy allows show as `open` or `closed`. Ports it blocks show as
`filtered`. Run the same scan from a client the policy shouldn't allow, and
compare.

Scan pod IPs, not Service IPs, when testing policies. A Service only forwards
the ports it defines, so other ports on a ClusterIP always look filtered,
whatever the policy says.

### Find pods with a port open

```sh
nmap -Pn -n -T4 -p 9090 --open 10.244.0.0/16
```

Get your pod network range from the node's routes ([ip](ip.md)) or from your
cluster's configuration. Scanning a `/16` takes a while. Scanning one node's
`/24` is much faster.

To scan the pods of one namespace, get their IPs from your own machine:

```sh
kubectl get pods -n my-namespace -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' > targets.txt
```

Copy the file into kdbg (`kubectl cp`), then run `nmap -Pn -p 8080 -iL targets.txt`.

### What does a node expose?

From a kdbg pod:

```sh
nmap -Pn -T4 -p- <node-ip>
```

This shows the ports reachable from pods: the kubelet (10250), NodePort
Services (30000 to 32767 by default), and anything running with host
networking. Compare with a scan from outside the cluster to see what's
exposed beyond it.

### Identify an unknown service

```sh
nmap -Pn -sV -p 8443 10.244.2.15
```

```text
PORT     STATE SERVICE  VERSION
8443/tcp open  ssl/http Golang net/http server
```

## Pitfalls

- **Without `-Pn`, nmap often says the host is down.** Before scanning, nmap
  checks if the host is up by sending pings and probes to ports 80 and 443.
  Pods often don't answer these, so nmap skips them. `-Pn` skips the check.
- **Missing `NET_RAW`** makes nmap fail even as root, because it assumes root
  can open raw sockets. Use `--unprivileged`.
- **Scanning a ClusterIP is misleading.** Only the Service's ports are
  forwarded to a pod. Every other port looks `filtered`.
- **Big scans are slow when things are filtered.** Every filtered port waits
  for a timeout. Narrow the port range, use `-T4`, and
  `--max-retries 1`.
- **UDP scans are slow and vague.** Many ports end up `open|filtered`. Test a
  specific UDP service by sending it a real request instead (for DNS, `dig`).
- **Scripts aren't installed.** See [What's not included](#whats-not-included).

## Related

- [nc](nc.md), for testing one port
- [tcptraceroute](tcptraceroute.md), to see where filtered traffic stops
- [ss](ss.md), to see from inside a pod what it listens on

## Manuals

- [nmap reference guide](https://nmap.org/book/man.html)
- [Port scanning techniques](https://nmap.org/book/man-port-scanning-techniques.html)
