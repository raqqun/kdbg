# iptraf-ng

`iptraf-ng` shows live network traffic in a full-screen terminal view: which
connections are active, how many packets and bytes each one carries, and how
much traffic each interface and port handles. Where [tcpdump](tcpdump.md)
prints every single packet, `iptraf-ng` gives you an overview that updates as
you watch.

## When to use it in a cluster

- Seeing which connections a pod has right now, and which ones are busy.
- Finding who sends traffic to a node, and how much.
- Checking which ports get the most traffic.
- Watching the bandwidth of an interface while you reproduce a problem.
- Checking packet sizes, for example when you suspect MTU problems.

## Privileges

`iptraf-ng` needs `NET_RAW`. See [Privileges](README.md#privileges). Its
settings include a promiscuous mode, which needs `NET_ADMIN`. In a pod it makes
no difference, so leave it off.

It also needs a terminal of at least 80 by 24 characters. Start kdbg with `-it`
(`kubectl run -it` or `kubectl debug -it`). If the screen looks garbled, run
`export TERM=xterm` and start it again.

## Starting it

```sh
iptraf-ng                  # Main menu
iptraf-ng -i all           # Go straight to the IP traffic monitor, all interfaces
iptraf-ng -i eth0          # IP traffic monitor on eth0
iptraf-ng -g               # General statistics for all interfaces
iptraf-ng -d eth0          # Detailed statistics for eth0
iptraf-ng -s eth0          # Traffic per TCP and UDP port on eth0
iptraf-ng -z eth0          # Packet sizes on eth0
iptraf-ng -l all           # LAN stations: traffic per MAC address
iptraf-ng -i all -t 5      # Run for 5 minutes, then exit
```

The keys you can use are listed at the bottom of each screen. `X` or `Q` goes
back or exits.

## The screens

### IP traffic monitor (`-i`)

The most useful screen. The top part lists TCP connections, two lines each (one
per direction). A simplified view:

```text
 TCP Connections (Source Host:Port)        Packets     Bytes  Flag  Iface
 ┌10.244.1.5:43210                      =      812     61220  -PA-  eth0
 └10.244.2.15:8080                      =     1630   2310442  -PA-  eth0
 ┌10.244.1.5:51882                      =        3       180  S---  eth0
 └10.244.3.9:5432                       =        0         0  ----  eth0

 UDP (76 bytes) from 10.244.1.5:51234 to 10.96.0.10:53 on eth0
 ICMP echo req (84 bytes) from 10.244.1.5 to 10.244.2.15 on eth0
```

- **Packets and Bytes** count what each direction sent since you started
  watching.
- **Flag** shows the last TCP flags seen: `S` SYN, `A` ACK, `P` data, `F` FIN,
  `R` reset. `CLOSED` and `RESET` mark ended connections.
- **The bottom part** lists other traffic (UDP, ICMP, and so on) as it
  happens.

A connection where one side keeps sending SYNs (`S---`) and the other side
shows nothing is a connection attempt that gets no answer.

You can sort connections by packets or bytes, to find the busiest ones.

### General interface statistics (`-g`)

One line per interface with packet counts and current rate. A quick way to see
which interface is busy, and to spot an interface with traffic you didn't
expect.

### Detailed interface statistics (`-d`)

Packets and bytes by protocol (IP, TCP, UDP, ICMP, and others) on one
interface, with current rates and how many packets were bad.

### TCP/UDP service monitor (`-s`)

Traffic grouped by port. Shows which services on this pod or node carry the
most traffic.

### Packet size counts (`-z`)

How many packets fall into each size range. If you see no packets near the
interface's MTU, while large transfers are happening, large packets may be
getting lost.

### LAN station monitor (`-l`)

Traffic per MAC address on the local network. Mostly useful on nodes.

## Running without a terminal

With `-B`, `iptraf-ng` runs in the background and writes to a log file instead
of the screen. Combine it with `-t` so it stops by itself:

```sh
iptraf-ng -i all -B -t 5 -L /tmp/traffic.log
```

The command returns at once and keeps logging for 5 minutes, one line per
packet or connection event:

```text
Sat Oct 10 11:56:10 2026; ******** IP traffic monitor started ********
Sat Oct 10 11:56:12 2026; UDP; eth0; 76 bytes; from 10.244.1.5:51234 to 10.96.0.10:53
...
```

This also works through `kubectl exec` without `-t`.

## Pitfalls

- **In a pod, you only see that pod's traffic.** To see a whole node's
  traffic, use `kubectl debug node/<node>`.
- **It refuses to start a screen after being stopped abruptly**, because old
  lock files are left behind. Start it with `-f` to clear them.
- **Counters start when you open a screen.** They don't show what happened
  before.
- **It's a live view, not a record.** To keep what you saw, use the log
  options, or capture with [tcpdump](tcpdump.md).

## Related

- [tcpdump](tcpdump.md), to look at individual packets
- [ss](ss.md), for a list of sockets and connections without capturing traffic
- [iperf3](iperf3.md), to generate traffic and measure bandwidth

## Manual

- [iptraf-ng](https://manpages.debian.org/stable/iptraf-ng/iptraf-ng.8.en.html)
