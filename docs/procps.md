# procps: ps, top and friends

kdbg includes `procps-ng`, the standard Linux tools for looking at processes
and memory. They replace the smaller busybox versions, so the usual options
work.

| Tool | What it does |
| --- | --- |
| `ps` | List processes |
| `top` | Live view of processes, CPU and memory |
| `pgrep`, `pkill` | Find or signal processes by name |
| `pidof`, `pidwait` | PIDs of a program, wait for processes to end |
| `free` | Memory usage |
| `vmstat` | Memory, CPU, I/O and context switches over time |
| `pmap` | Memory map of a process |
| `pwdx` | Working directory of a process |
| `uptime`, `w` | Uptime and load average |
| `watch` | Run a command every few seconds |
| `sysctl` | Read and set kernel parameters |
| `slabtop` | Kernel memory caches |

## When to use them in a cluster

- Seeing which processes run in a container, and which ones use CPU and memory.
- Finding processes that are stuck, or zombies piling up.
- Finding the PID for [strace](strace.md), [lsof](lsof.md) or `nsenter`.
- On a node: seeing what uses the node's CPU and memory.

## Privileges

Listing processes needs no privileges, but you only see the processes you
share a process namespace with:

- In a kdbg pod of its own: only kdbg.
- With `kubectl debug <pod> --target=<container>`: the target container's
  processes.
- With `kubectl debug node/<node>`: every process on the node, including all
  pods' containers.
- In a pod with `shareProcessNamespace: true`: all containers of the pod.

Some details, like a process's environment, need `SYS_PTRACE` when the process
runs as another user.

## ps

```sh
ps aux                                    # All processes, BSD style: %CPU, %MEM, RSS, STAT
ps -ef                                    # All processes, with parent PID
ps -ef --forest                           # As a tree
ps -eo pid,ppid,user,stat,%cpu,%mem,rss,etime,args --sort=-rss | head   # Biggest memory users first
ps -eo pid,stat,wchan:32,args             # What each process is waiting for in the kernel
ps -T -p 1                                # Threads of PID 1
ps -o pid,nlwp,args -p 1                  # Number of threads
ps -eo pid,stat,args | awk '$2 ~ /^Z/'    # Zombie processes
```

### Reading the output

```text
USER   PID %CPU %MEM    VSZ   RSS TTY  STAT START   TIME COMMAND
app      1  2.1  3.4 1825412 281232 ?  Ssl  09:12   1:43 java -jar /app/app.jar
app     57  0.0  0.0   1612   896 ?    Z    09:40   0:00 [sh] <defunct>
```

- **RSS** is the memory the process really uses, in KiB. **VSZ** is how much
  it has reserved, which is usually much larger and rarely matters.
- **%CPU** is the average over the process's whole life, not right now. Use
  `top` for current usage.
- **TIME** is the total CPU time used.

The **STAT** column:

| Code | Meaning |
| --- | --- |
| `R` | Running, or ready to run |
| `S` | Sleeping, waiting for something. Normal. |
| `D` | Waiting for I/O, and can't be interrupted. Many processes in `D` for long means storage trouble, often a hung network volume (NFS, for example). |
| `Z` | Zombie: finished, but its parent hasn't collected its exit status |
| `T` | Stopped |
| `s` | Session leader |
| `l` | Has several threads |
| `<`, `N` | Higher or lower priority than normal |

`wchan` names the kernel function a sleeping process waits in. It helps with
`D` processes: names mentioning `nfs` or `rpc` point to a network volume.

## top

```sh
top                     # Live view
top -b -n 1 | head -30  # One snapshot as text: works without a terminal
top -H -p 1             # Threads of PID 1
top -d 5                # Update every 5 seconds
```

Keys in the live view:

| Key | Action |
| --- | --- |
| `P` | Sort by CPU |
| `M` | Sort by memory |
| `1` | Show each CPU separately |
| `c` | Show full command lines |
| `H` | Show threads instead of processes |
| `k` | Send a signal to a process |
| `q` | Quit |

The header:

```text
top - 11:58:46 up 20 days,  2 users,  load average: 3.12, 2.80, 2.71
Tasks: 214 total,   2 running, 212 sleeping,   0 stopped,   0 zombie
%Cpu(s): 23.1 us,  4.2 sy,  0.0 ni, 70.9 id,  1.1 wa,  0.0 hi,  0.4 si,  0.3 st
MiB Mem :  15928.4 total,   1203.1 free,   9811.2 used,   4914.1 buff/cache
```

- **load average** over 1, 5 and 15 minutes: roughly how many processes want
  CPU at once. Compare it with the number of CPUs.
- **us** and **sy**: CPU time in programs and in the kernel.
- **wa**: CPUs idle while waiting for I/O. High values point to slow storage.
- **st** (steal): time the cloud's hypervisor gave this machine's CPU to
  someone else. High values mean the node is short on real CPU.
- **%CPU** of a process can go above 100: 200% means two full CPUs.

## Memory and CPU limits: an important pitfall

`top`, `free` and `vmstat` show the **whole machine's** memory and CPUs, not
the container's limits. A container limited to 512 MiB still sees all the
node's memory in `free`.

The real limits and usage are in the container's cgroup. For kdbg's own
container:

```sh
cat /sys/fs/cgroup/memory.max       # Memory limit in bytes ("max": no limit)
cat /sys/fs/cgroup/memory.current   # Memory used now
cat /sys/fs/cgroup/memory.events    # "oom_kill" counts kills for running out of memory
cat /sys/fs/cgroup/cpu.max          # CPU limit: "200000 100000" means 2 CPUs; "max" means none
cat /sys/fs/cgroup/cpu.stat         # "nr_throttled", "throttled_usec": time held back by the CPU limit
```

For a target container (with `--target`), read the same files through one of
its processes:

```sh
cat /proc/1/root/sys/fs/cgroup/memory.max
cat /proc/1/root/sys/fs/cgroup/memory.events
cat /proc/1/root/sys/fs/cgroup/cpu.stat
```

**CPU throttling** is a common reason for slowness that `top` doesn't show: a
container that hits its CPU limit gets paused for the rest of each 100 ms
period. If `nr_throttled` keeps growing during the slow periods, the CPU limit
is too low for the load.

## Other tools

```sh
pgrep -a nginx            # PIDs and command lines of processes matching "nginx"
pkill -HUP nginx          # Send SIGHUP to them (many servers reload config on it)
pidof java                # PIDs of a program
free -m                   # Machine memory in MiB
vmstat 1 10               # Every second, 10 times: run queue, memory, swap, I/O, CPU
pmap -x 1 | tail -1       # Total memory mapped by PID 1
pwdx 1                    # Working directory of PID 1
watch -n 2 'ss -s'        # Run a command every 2 seconds
sysctl net.ipv4.ip_local_port_range   # Read a kernel setting
```

In `vmstat`, the `r` column is the number of processes waiting for CPU. If it's
often higher than the number of CPUs, the machine is overloaded. `si` and `so`
above zero mean the machine is swapping.

## Recipes

### What's running in this container?

```sh
kubectl debug -it <pod> --image=ghcr.io/raqqun/kdbg --target=<container> -- ps -ef --forest
```

You see the application, any processes it started, and kdbg's own shell.

### Zombies piling up

```sh
ps -eo pid,ppid,stat,args | awk '$3 ~ /^Z/'
```

Zombies are processes that ended but whose parent never collected their exit
status. In containers this usually happens when the application runs as PID 1
and starts child processes (shell scripts, health check commands) without
reaping them. A few are harmless. Thousands use up the process limit, and new
processes fail to start.

Fix it by running a minimal init as PID 1, like `tini` (or Docker's
`--init`), or with `shareProcessNamespace: true` in the pod, which makes the
pause container PID 1.

### Who uses the node's CPU and memory?

```sh
kubectl debug node/<node> -it --image=ghcr.io/raqqun/kdbg -- top
```

Press `M` to sort by memory, `P` for CPU. Processes inside pods show up like
any others. To find which pod a process belongs to:

```sh
cat /proc/<pid>/cgroup
```

The path contains the pod's UID (`pod<uid>`) and the container ID. With the
systemd cgroup driver, the dashes in the UID are replaced by underscores. Look
the UID up with `kubectl get pods -A -o custom-columns=NAME:.metadata.name,UID:.metadata.uid | grep <uid>`.

### A process stuck in D state

```sh
ps -eo pid,stat,wchan:32,args | awk '$2 ~ /^D/'
```

Processes in `D` can't be killed, not even with `kill -9`, until the I/O they
wait on finishes. Check the volumes the pod mounts, and the node's storage.

## Pitfalls

- **You only see processes in your process namespace.** See
  [Privileges](#privileges).
- **Machine-wide numbers.** `top`, `free` and `vmstat` show the node, not the
  container. See [Memory and CPU limits](#memory-and-cpu-limits-an-important-pitfall).
- **`%CPU` in `ps` is a lifetime average.** For current usage use `top`.
- **Signals reach the real process.** `kill` and `pkill` from kdbg work on the
  target container's processes. Killing PID 1 restarts the container.

## Related

- [strace](strace.md), to see what a process is doing
- [lsof](lsof.md), to see what it has open
- [ss](ss.md), to see its network connections

## Manuals

- [ps](https://manpages.debian.org/stable/procps/ps.1.en.html)
- [top](https://manpages.debian.org/stable/procps/top.1.en.html)
- [vmstat](https://manpages.debian.org/stable/procps/vmstat.8.en.html)
- [cgroup v2 files](https://docs.kernel.org/admin-guide/cgroup-v2.html)
