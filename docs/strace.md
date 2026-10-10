# strace

`strace` shows the system calls a process makes: every time it opens a file,
connects to a server, reads from a socket, sleeps or waits for something, it
asks the kernel, and `strace` prints each request and its result. When an
application hangs, fails without a useful error, or is slow for no obvious
reason, `strace` shows what it's actually doing.

## When to use it in a cluster

- An application hangs: see what it's waiting on.
- It fails with a vague error: see which file, address or call failed.
- Finding which config files it reads, and which ones it looks for but
  doesn't find.
- Finding which hosts it connects to.
- Seeing where its time goes.

## Privileges

`strace` needs `SYS_PTRACE` and has to see the target's processes. Attach kdbg
to the pod with the `general` profile:

```sh
kubectl debug -it <pod> --image=ghcr.io/raqqun/kdbg --target=<container> --profile=general -- bash
```

Then find the process with `ps -ef` (see [procps](procps.md)). The
application is often PID 1.

## Running it with care

`strace` slows the traced process down, sometimes a lot, because the kernel
stops it at every system call. On a busy production process this can cause
timeouts and failed health checks. Trace for a short time, trace only the calls
you need (`-e`), and prefer `-c` for a first look.

## Common commands

```sh
strace -p 1                         # Attach to PID 1, print every system call
strace -f -p 1                      # Include all threads and child processes. Needed for most applications.
strace -f -tt -T -p 1               # With timestamps, and the time spent in each call
strace -f -e trace=%network -p 1    # Only network calls
strace -f -e trace=%file -p 1       # Only calls that take a file name
strace -f -e trace=connect,sendto,recvfrom -p 1   # Only these calls
strace -f -Z -p 1                   # Only calls that failed
strace -f -yy -p 1                  # Show what each file descriptor is: path, or socket addresses
strace -f -s 256 -p 1               # Show up to 256 characters of strings (default 32)
strace -f -c -p 1                   # Count calls and time; print a summary on Ctrl+C
strace -f -o /tmp/trace.txt -p 1    # Write to a file instead of the screen
strace -f -o /tmp/trace.txt curl -s http://my-svc   # Start a command under strace
```

| Option | What it does |
| --- | --- |
| `-p PID` | Attach to a running process. Repeat it for several. |
| `-f` | Follow threads and child processes |
| `-e trace=...` | Which calls to show: names, or classes like `%network`, `%file`, `%process`, `%memory`, `%signal` |
| `-Z` | Only show calls that failed |
| `-tt` | Timestamp with microseconds |
| `-T` | Time spent inside each call |
| `-y`, `-yy` | Show file paths for descriptors, and addresses for sockets |
| `-s N` | Maximum string length to print |
| `-c` | Summary table instead of individual calls |
| `-o FILE` | Write output to a file. With `-ff`, one file per thread. |

Press Ctrl+C to detach. The process carries on as before.

## Reading the output

Each line is one call: its name, its arguments, and after `=` the result:

```text
openat(AT_FDCWD, "/etc/app/config.yaml", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/config/config.yaml", O_RDONLY|O_CLOEXEC) = 7
read(7, "server:\n  port: 8080\n"..., 4096) = 412
connect(9, {sa_family=AF_INET, sin_port=htons(5432), sin_addr=inet_addr("10.96.33.4")}, 16) = -1 EINPROGRESS (Operation now in progress)
```

- A result of `-1` is a failure, followed by the error name and description.
  `ENOENT` is "file not found", `EACCES` "permission denied",
  `ECONNREFUSED` "connection refused", `ETIMEDOUT` "timed out".
- Not every failure is a problem. Applications often try several paths before
  finding the right one, and `EAGAIN` or `EINPROGRESS` on sockets are part of
  normal non-blocking I/O.
- `<unfinished ...>` and `<... resumed>` mark a call that was interrupted in
  the output by another thread's call, and its continuation.
- With `-f`, each line starts with `[pid N]`, the thread that made the call.

Calls you'll see often when something waits:

| Call | Waiting for |
| --- | --- |
| `read`, `recvfrom`, `recvmsg` | Data from a file or socket |
| `connect` | A connection to open |
| `poll`, `select`, `epoll_wait` | Any of several file descriptors to become ready. Normal for idle servers. |
| `futex` | Another thread: a lock or condition. Normal for idle threads. |
| `nanosleep`, `clock_nanosleep` | A timer |
| `wait4`, `waitid` | A child process to finish |

## Recipes

### Why does it hang?

```sh
strace -f -tt -yy -p 1
```

Look at the calls that don't return. With `-yy`, a blocked
`read(9<TCP:[10.244.1.5:43210->10.96.33.4:5432]>, ...` tells you it's waiting
for data from the server at `10.96.33.4:5432`. Find out who that is, and test
it with [nc](nc.md).

If every thread sits in `futex` or `epoll_wait` and nothing else happens, the
application is waiting for work, or is stuck on an internal lock that `strace`
can't explain. Look at the application's own debugging tools (thread dumps,
profilers) next.

### Which files does it look for?

```sh
strace -f -e trace=%file -Z -p 1
```

Only the failed file calls. A config file, certificate or library it can't find
shows up as `ENOENT`. `EACCES` means it's there but can't be read, often a
wrong `fsGroup` or file mode on a mounted volume.

### Where does it connect to?

```sh
strace -f -e trace=connect -p 1
```

Every connection attempt, with the IP and port. Useful when an application
connects somewhere other than you think, for example an old database address.

### Is DNS the slow part?

```sh
strace -f -tt -T -e trace=%network -p 1
```

Look for `sendto` and `recvfrom` calls to port 53. The `-T` time on them, and
the gap between a query and its answer, show how long lookups take.

### Where does the time go?

```sh
strace -f -c -p 1
# wait a few seconds, then Ctrl+C
```

```text
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 61.23    0.412345         412      1001           futex
 20.11    0.135432          27      5012       102 read
 ...
```

A call that dominates, or one with many `errors`, is the place to look. For
example, thousands of failed `openat` calls point to the application searching
for a file again and again.

### Trace a command from start to finish

When you can reproduce the problem with a command in kdbg, trace the whole
thing:

```sh
strace -f -tt -o /tmp/trace.txt curl -s https://my-svc
```

Then copy the file out (see [Getting files out](README.md#getting-files-out)).

## Pitfalls

- **`ptrace(PTRACE_SEIZE, ...): Operation not permitted`** means kdbg doesn't
  have `SYS_PTRACE` (use `--profile=general`), or the node forbids tracing.
  Check `/proc/sys/kernel/yama/ptrace_scope`: `3` means tracing is disabled
  entirely on that node.
- **Only one tracer at a time.** If another `strace` or a debugger is attached,
  attaching fails.
- **Without `-f` you only see one thread.** Most servers (Go, Java, Node.js
  with workers, anything with a thread pool) do their work in other threads,
  so you'd see almost nothing.
- **File paths are the target's.** Paths in the output are as the traced
  process sees them, in its own container. To open those files from kdbg, go
  through `/proc/<pid>/root/`, for example `cat /proc/1/root/etc/app/config.yaml`.
- **It can't trace a process that crashes on start** before you attach. Read
  `kubectl logs --previous` first.
- **High overhead.** See [Running it with care](#running-it-with-care).

## Related

- [lsof](lsof.md), for all files and sockets a process has open right now
- [procps](procps.md), to find the process and see its state
- [ss](ss.md), for the state of its network connections

## Manual

- [strace](https://manpages.debian.org/stable/strace/strace.1.en.html)
