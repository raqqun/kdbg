# DNS: dig, nslookup, host

`dig`, `nslookup` and `host` all ask a DNS server for the records of a name.
They come from the same package (BIND's `bind-tools`) and differ mostly in how
much they show:

- **`dig`** shows the full answer: response code, flags, every record, which
  server answered and how long it took. Use it when you need to understand
  *why* a lookup behaves the way it does.
- **`host`** prints short, readable answers. Good for a quick check.
- **`nslookup`** is the one many people already know. It works, but `dig` gives
  you more.

Many "can't connect" problems in a cluster turn out to be DNS problems, so this
is often the first thing to check.

## How DNS works in a pod

Every pod gets an `/etc/resolv.conf` written by the kubelet. It usually looks
like this:

```text
search my-namespace.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

- **`nameserver`** is the ClusterIP of the cluster DNS service (CoreDNS, in the
  `kube-system` namespace, usually named `kube-dns`). With NodeLocal DNSCache
  it is `169.254.20.10` instead, a cache running on every node.
- **`search`** lists suffixes tried for short names. That is why `my-svc` works
  from the same namespace and `my-svc.other-namespace` works from any
  namespace.
- **`ndots:5`** means a name with fewer than five dots is tried with every
  search suffix *before* being tried as-is. `api.example.com` has two dots, so
  the pod first asks for `api.example.com.my-namespace.svc.cluster.local`,
  then the other suffixes, and only then `api.example.com`.
- **`cluster.local`** is the default cluster domain, but it can be changed. If
  the `search` line shows something else, use that wherever these guides say
  `cluster.local`.

Names that exist in the cluster:

| Name | Resolves to |
| --- | --- |
| `<svc>.<namespace>.svc.cluster.local` | The Service's ClusterIP |
| Same, for a headless Service (`clusterIP: None`) | The IPs of the Service's ready pods |
| `<pod-name>.<svc>.<namespace>.svc.cluster.local` | One pod of a StatefulSet, through its headless Service |
| `_<port-name>._<protocol>.<svc>.<namespace>.svc.cluster.local` | SRV record: the port number and target name of a named Service port |
| `<a-b-c-d>.<namespace>.pod.cluster.local` | The pod with IP `a.b.c.d` (dashes instead of dots) |
| An `ExternalName` Service | A CNAME to the external name |

## Privileges

None. These tools work in any pod.

## dig

### Basic lookup

```sh
dig my-svc.my-namespace.svc.cluster.local
```

```text
; <<>> DiG 9.20.x <<>> my-svc.my-namespace.svc.cluster.local
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 41263
;; flags: qr aa rd; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; QUESTION SECTION:
;my-svc.my-namespace.svc.cluster.local. IN A

;; ANSWER SECTION:
my-svc.my-namespace.svc.cluster.local. 30 IN A 10.96.142.17

;; Query time: 1 msec
;; SERVER: 10.96.0.10#53(10.96.0.10) (UDP)
;; WHEN: ...
;; MSG SIZE  rcvd: 119
```

### Reading the output

- **`status`** is the most important field:
  - `NOERROR` with an answer: the name exists and resolved.
  - `NOERROR` with `ANSWER: 0`: the name exists but has no record of the type
    you asked for. Common for `AAAA` (IPv6) lookups in IPv4-only clusters.
  - `NXDOMAIN`: the name doesn't exist. Check for typos, the namespace, and
    the cluster domain.
  - `SERVFAIL`: the DNS server couldn't get an answer. For external names this
    usually means CoreDNS can't reach its upstream servers.
  - `REFUSED`: the server won't answer this query.
- **No reply at all** (`;; communications error ... timed out` or
  `no servers could be reached`): the query never got an answer. The DNS
  service is down, or something (often a NetworkPolicy) blocks traffic to it.
- **`flags`**: `aa` means the server is authoritative for the name, which
  CoreDNS is for cluster names. `ra` means it will look up other names
  recursively for you.
- **The number after the name** (`30` above) is the TTL in seconds: how long
  clients may cache the answer.
- **`Query time`** shows how long the answer took. Cluster names should answer
  in a few milliseconds. Hundreds of milliseconds, or exactly 5 seconds, point
  to a problem (see [Pitfalls](#pitfalls)).
- **`SERVER`** shows which server answered and whether over UDP or TCP.

### Useful options

```sh
dig +short my-svc.my-namespace.svc.cluster.local     # Only the answer
dig +noall +answer my-svc.my-namespace.svc.cluster.local  # Only the answer section, with TTLs
dig +search my-svc                                   # Use the search list from resolv.conf
dig @10.244.1.7 my-svc.my-namespace.svc.cluster.local    # Ask a specific server
dig AAAA my-svc.my-namespace.svc.cluster.local       # IPv6 address
dig SRV _http._tcp.my-svc.my-namespace.svc.cluster.local  # SRV record of a named port
dig -x 10.244.1.23                                   # Reverse lookup: IP to name
dig +tcp my-svc.my-namespace.svc.cluster.local       # Use TCP instead of UDP
dig +timeout=1 +tries=1 example.com                  # Fail fast
dig +trace example.com                               # Follow delegation from the root servers
```

`dig` exits with status `0` when it got an answer (even `NXDOMAIN`), and `9`
when no server replied. That makes it easy to use in loops.

## host

```sh
host my-svc                       # Uses the search list, like an application would
host -t SRV _http._tcp.my-svc.my-namespace.svc.cluster.local
host 10.244.1.23                  # Reverse lookup
host my-svc 10.244.1.7            # Ask a specific server
host -v my-svc                    # Detailed output, close to dig's
```

```text
my-svc.my-namespace.svc.cluster.local has address 10.96.142.17
```

## nslookup

```sh
nslookup my-svc                   # Uses the search list
nslookup my-svc 10.244.1.7        # Ask a specific server
nslookup -type=SRV _http._tcp.my-svc.my-namespace.svc.cluster.local
nslookup -debug my-svc            # Show every query it sends
```

```text
Server:     10.96.0.10
Address:    10.96.0.10#53

Name:   my-svc.my-namespace.svc.cluster.local
Address: 10.96.142.17
```

## Recipes

### Does a Service resolve?

```sh
dig +short my-svc.my-namespace.svc.cluster.local
```

An IP means DNS is fine, and the problem is somewhere after it. Nothing, or
`NXDOMAIN` in the full output, means the Service doesn't exist under that name.
Check the name and namespace with `kubectl get svc -n my-namespace`.

A ClusterIP Service resolves even when it has no ready pods behind it. A
successful lookup doesn't prove there's anything to connect to. Check
`kubectl get endpointslices -n my-namespace -l kubernetes.io/service-name=my-svc`.

### Is cluster DNS working at all?

```sh
dig +short kubernetes.default.svc.cluster.local
```

The `kubernetes` Service always exists. If this fails, the problem is with
cluster DNS itself, not your Service.

### Is one CoreDNS replica bad?

Queries to the DNS ClusterIP are spread across the CoreDNS pods. If only some
lookups fail, one replica may be broken. List the CoreDNS pods from your own
machine:

```sh
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```

Then ask each one directly from kdbg:

```sh
for ip in 10.244.0.5 10.244.1.7; do
  echo "== $ip"
  dig @$ip +short +timeout=2 +tries=1 kubernetes.default.svc.cluster.local
  dig @$ip +short +timeout=2 +tries=1 example.com
done
```

If cluster names work but external names fail on a replica, its upstream
forwarding is broken. Look at that pod's logs and the `forward` line in the
`coredns` ConfigMap.

### Catch intermittent failures

A single lookup proves little when failures are occasional. Run many:

```sh
for i in $(seq 200); do
  dig +timeout=2 +tries=1 my-svc.my-namespace.svc.cluster.local > /dev/null || echo "lookup $i failed"
done
```

To see slow answers rather than failures, print the query time of each:

```sh
for i in $(seq 50); do
  dig my-svc.my-namespace.svc.cluster.local | awk '/Query time/{print $4 " ms"}'
done
```

### Headless Services and StatefulSets

```sh
dig +short my-headless.my-namespace.svc.cluster.local     # One IP per ready pod
dig +short web-0.my-headless.my-namespace.svc.cluster.local  # A single StatefulSet pod
dig +short SRV _grpc._tcp.my-headless.my-namespace.svc.cluster.local
```

A headless Service only returns pods that are ready, unless it sets
`publishNotReadyAddresses: true`. If the list is shorter than expected, check
the readiness of the missing pods.

### Check what an application would see

`dig` uses its own resolver and ignores the search list unless you pass
`+search`. Applications use the system's resolver. To get closer to what an
application sees, use `getent`, which uses the image's own resolver:

```sh
getent hosts my-svc
```

Keep in mind that kdbg uses musl (Alpine's C library), while many application
images use glibc. They handle `resolv.conf` slightly differently, so a lookup
can behave differently in kdbg than in the application's own container. When in
doubt, run the lookup in the application container itself, with
`kubectl debug --target` and its network namespace.

### Count the queries an external name costs

Because of `ndots:5`, a lookup of `api.example.com` from a pod first tries
every search suffix. Watch it happen:

```sh
nslookup -debug api.example.com | grep -A1 QUESTIONS | grep type
```

```text
	api.example.com.my-namespace.svc.cluster.local, type = A, class = IN
	api.example.com.svc.cluster.local, type = A, class = IN
	api.example.com.cluster.local, type = A, class = IN
	api.example.com, type = A, class = IN
	api.example.com, type = AAAA, class = IN
```

A name ending in a dot (`api.example.com.`) is treated as complete and skips
the search list. Lowering `ndots` in the pod's `dnsConfig` has the same effect
for every name in that pod.

## Pitfalls

- **`dig` ignores the search list.** `dig my-svc` asks for the literal name
  `my-svc` and fails, even though `curl http://my-svc` works. Use the full name,
  or `dig +search my-svc`. `host` and `nslookup` do use the search list.
- **NetworkPolicies must allow DNS.** A policy that restricts egress has to
  allow traffic to the CoreDNS pods on port 53, over both UDP and TCP. Lookups
  that time out right after a policy was added are almost always this.
- **Large answers use TCP.** If an answer doesn't fit in a UDP packet, the
  client retries over TCP. If TCP 53 is blocked, lookups of names with many
  records (like big headless Services) fail while small ones work. Test with
  `dig +tcp`.
- **5-second delays.** Lookups that take almost exactly 5 seconds are a classic
  symptom of dropped UDP packets: the resolver waits 5 seconds and retries. A
  known cause is a race in the Linux connection tracking table when a client
  sends its A and AAAA queries at the same moment. `dig` sends one query at a
  time, so it may not reproduce what the application sees. See
  [conntrack](conntrack.md) to look for insert failures on the node.
- **Applications cache answers.** If `dig` shows the new IP but the application
  still connects to the old one, the application (Java is known for this) or a
  library may be caching the old answer.
- **Pod IPs change.** A pod's DNS record changes when the pod is replaced.
  Don't hard-code pod IPs from a lookup; use the Service name.
- **ICMP isn't DNS.** "ping: bad address" means the name didn't resolve, not
  that the host is down.

## Related

- [nc](nc.md), to check that the resolved address actually accepts connections
- [tcpdump](tcpdump.md), to watch DNS traffic: `tcpdump -ni any port 53`
- [conntrack](conntrack.md), for dropped DNS packets on a node

## Manuals

- [dig](https://bind9.readthedocs.io/en/latest/manpages.html#dig-dns-lookup-utility)
- [host](https://bind9.readthedocs.io/en/latest/manpages.html#host-dns-lookup-utility)
- [nslookup](https://bind9.readthedocs.io/en/latest/manpages.html#nslookup-query-internet-name-servers-interactively)
- [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [Debugging DNS resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
