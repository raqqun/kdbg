# lsof

`lsof` lists open files. On Linux almost everything is a file: regular files,
directories, sockets, pipes, devices. So `lsof` shows which files, network
connections and pipes a process holds, or which processes hold a given file or
port.

## When to use it in a cluster

- An application fails with `too many open files`.
- A volume or the container's disk is full, but `du` doesn't find the space:
  often deleted files that are still held open.
- Finding which process holds a port or a file.
- Seeing which config files, certificates and sockets an application really
  uses.

## Privileges

To see another container's processes, attach kdbg to the pod with
`kubectl debug --target`. Seeing the files of a process running as another
user needs `SYS_PTRACE`, so use `--profile=general`:

```sh
kubectl debug -it <pod> --image=ghcr.io/raqqun/kdbg --target=<container> --profile=general -- bash
```

## Common commands

```sh
lsof -p 1                       # Everything PID 1 has open
lsof -nP -p 1                   # Same, numbers instead of host and port names (faster)
lsof -nP -i                     # All network sockets
lsof -nP -i :8080               # Who uses port 8080?
lsof -nP -i TCP -sTCP:LISTEN    # Listening TCP sockets
lsof -nP -i TCP -sTCP:ESTABLISHED   # Open TCP connections
lsof -nP -i @10.244.2.15        # Connections to or from this IP
lsof -nP +L1                    # Files that are deleted but still open
lsof /data/app.log              # Who has this file open?
lsof +D /data                   # Who has anything under /data open? (slow on big trees)
lsof -c java                    # Processes whose name starts with "java"
lsof -t -i :8080                # Only PIDs: handy in scripts
lsof -a -p 1 -i                 # -a combines conditions with AND: PID 1's network sockets
```

| Option | What it does |
| --- | --- |
| `-p PID` | Files of this process |
| `-c NAME` | Files of processes whose name starts with NAME |
| `-u USER` | Files of processes owned by USER |
| `-i [addr]` | Network sockets, optionally matching `:port`, `@host`, `TCP`, `UDP` |
| `-sTCP:STATE` | With `-i`: only TCP sockets in this state |
| `-n`, `-P` | Don't look up host names, port names |
| `+L1` | Files with fewer than 1 link: deleted but still open |
| `+D DIR` | Everything open under a directory |
| `-a` | AND the conditions together (default is OR) |
| `-t` | Print only PIDs |
| `-w` | Hide warnings |

## Reading the output

```text
COMMAND PID USER   FD   TYPE  DEVICE SIZE/OFF    NODE NAME
app       1 app   cwd    DIR   0,57        28 1007058 /app
app       1 app   txt    REG   0,57  21346304 1007061 /app/server
app       1 app     0r  FIFO   0,13       0t0   41233 pipe
app       1 app     1w  FIFO   0,13       0t0   41234 pipe
app       1 app     6u  IPv4  52113       0t0     TCP *:8080 (LISTEN)
app       1 app     7u  IPv4  52119       0t0     TCP 10.244.1.5:43210->10.96.33.4:5432 (ESTABLISHED)
app       1 app     8r   REG   0,63      1675   12901 /etc/tls/tls.key
app       1 app     9w   REG  253,1  52428800    8811 /var/log/app.log (deleted)
```

- **FD** is the file descriptor. Numbers are regular descriptors, followed by
  the mode: `r` read, `w` write, `u` both. Special values: `cwd` (working
  directory), `rtd` (root directory), `txt` (the program itself), `mem`
  (memory-mapped files like libraries).
- **TYPE**: `REG` regular file, `DIR` directory, `IPv4`/`IPv6` network socket,
  `unix` Unix socket, `FIFO` pipe, `CHR` device, `a_inode` kernel objects like
  epoll.
- **SIZE/OFF** is the file size, or the current offset.
- **NAME** is the path, or for sockets the addresses and state. `(deleted)`
  marks a file that has been removed but is still open.

## Recipes

### "Too many open files"

Count the descriptors the process has, and compare with its limit:

```sh
lsof -p 1 | wc -l
grep 'open files' /proc/1/limits
```

If the count is close to the limit, find out what most of them are:

```sh
lsof -nP -p 1 | awk 'NR>1 {print $5}' | sort | uniq -c | sort -rn
```

Many `IPv4` or `IPv6` entries means connections aren't being closed or
reused. Look at their state and destination with [ss](ss.md). Many `REG`
entries means files aren't being closed. Run the count again a few minutes
later: if it keeps growing, it's a leak.

### Disk full, but nothing big on it

When a file is deleted while a process still has it open, its space isn't freed
until the process closes it. A common case is a log file rotated or removed
while the application keeps writing to it. This fills `emptyDir` volumes and
the container's writable layer, and can get the pod evicted.

```sh
lsof -nP +L1
```

The `SIZE/OFF` column shows how much space each one holds. Restarting the
process frees it. To free it without a restart, empty the file through the
process's descriptor:

```sh
: > /proc/<pid>/fd/<fd-number>
```

### Who holds this port?

```sh
lsof -nP -i :8080
```

When an application fails with `address already in use`, this shows which
process already listens on the port.

### What does the application actually read?

```sh
lsof -nP -p 1 | grep REG
```

Shows which config files, certificates and other files are open right now. If
the application should have reloaded a changed ConfigMap or Secret, check
whether it still holds the old file.

## Pitfalls

- **Warnings like `can't stat() overlay file system`** are common in
  containers and harmless. Hide them with `-w`.
- **Without `--target`, you only see kdbg's own processes.** On a node
  (`kubectl debug node/<node>`), you see everything, but `lsof` without
  filters is slow. Narrow it with `-p`, `-c` or `-i`.
- **Paths are as the process sees them.** A file that `lsof` lists as
  `/etc/tls/tls.key` is in the *target* container's filesystem. From kdbg, open
  it as `/proc/<pid>/root/etc/tls/tls.key`.
- **`-n` and `-P` make a big difference in speed.** Without them, `lsof` looks
  up a name for every address and port.
- **`(stat: Operation not permitted)`** next to entries means kdbg isn't
  allowed to inspect that process fully. Add `--profile=general`.

## Related

- [ss](ss.md), for network sockets in more detail
- [strace](strace.md), to see files and sockets being opened as it happens
- [procps](procps.md), to find the process

## Manual

- [lsof](https://manpages.debian.org/stable/lsof/lsof.8.en.html)
