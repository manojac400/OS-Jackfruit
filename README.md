# Multi-Container Runtime - Operating Systems Project

## Team Information

| Name | SRN |
|------|-----|
| Manoj A C | PES1UG25CS826 |
| Ruthik | PES1UG25CS837 |

---

## Engineering Analysis

### 1. Isolation Mechanisms

Our runtime uses three Linux namespaces to achieve process and filesystem isolation:

- **CLONE_NEWPID**: Each container gets its own PID namespace. Process IDs inside the container start from 1, making them unable to see or signal processes in other containers or on the host.

- **CLONE_NEWNS**: Each container gets its own mount namespace. Combined with `chroot()`, each container sees only its assigned root filesystem as `/`.

- **CLONE_NEWUTS**: Each container gets its own UTS namespace, allowing independent hostnames.

**What the host kernel still shares with all containers:**
- The same kernel instance
- CPU cores and physical memory (though limited via kernel module)
- Network interface
- Device files

### 2. Supervisor and Process Lifecycle

**Why a long-running parent supervisor?**
- Centralized management of all containers from a single process
- Maintains metadata (PIDs, states, limits) for each container
- Handles SIGCHLD to reap zombie processes
- Provides IPC endpoint for CLI commands via UNIX socket

**Process lifecycle:**
When a container process terminates, the supervisor receives SIGCHLD and calls `waitpid()` to reap it. The container's state is updated from RUNNING to EXITED/STOPPED/KILLED in the metadata linked list.

**Signal delivery:**
- `SIGTERM` to supervisor triggers orderly shutdown of all containers
- `SIGTERM` to container (via `stop` command) allows graceful termination
- `SIGKILL` is only sent by the kernel module when hard memory limit is exceeded

### 3. IPC, Threads, and Synchronization

**Two IPC mechanisms used:**

| Mechanism | Purpose | Direction |
|-----------|---------|-----------|
| UNIX Domain Socket | Control commands (start, stop, ps, logs) | CLI → Supervisor |
| Pipes | Container stdout/stderr capture | Container → Supervisor |

**Bounded Buffer Design:**
The logging system uses a producer-consumer pattern with a circular buffer of size 16.

- **Producers**: Pipe reader threads read container output and push to buffer
- **Consumers**: Logger thread pops from buffer and writes to log files

**Synchronization primitives:**

| Primitive | Purpose |
|-----------|---------|
| `pthread_mutex_t` | Protect buffer head, tail, and count |
| `pthread_cond_t not_empty` | Signal consumers when data is available |
| `pthread_cond_t not_full` | Block producers when buffer is full |
| `shutting_down` flag | Signal threads to exit cleanly |

**Race conditions prevented:**
- Without mutex: Two producers could corrupt buffer indices simultaneously
- Without condition variables: Producers would spin-waste CPU or lose data
- Without shutdown flag: Threads could deadlock during exit

### 4. Memory Management and Enforcement

**What RSS measures:**
RSS (Resident Set Size) measures physical memory currently in RAM.

**What RSS does NOT measure:**
- Memory that has been swapped out
- Shared libraries (counted once per process)
- Memory-mapped files
- Virtual memory not yet allocated

**Soft vs Hard limits:**

| Limit | Behavior | Use Case |
|-------|----------|----------|
| Soft limit | Log warning only, process continues | Early notification, monitoring |
| Hard limit | Send SIGKILL, process terminates | Enforcement, prevent system degradation |

**Why enforcement belongs in kernel space:**
1. Cannot be bypassed - user-space monitoring can be killed by the container
2. Real-time enforcement - kernel checks memory on every allocation
3. System-wide view - kernel sees all memory usage across containers
4. Security - container cannot block or ignore SIGKILL

The kernel module uses a timer callback that checks RSS every 1 second. When hard limit is exceeded, the kernel sends SIGKILL directly.

### 5. Scheduling Behavior

**Experiment Design:**
Two CPU-bound containers running `cpu_hog` with different nice values on the same CPU core:

| Container | Nice Value | Priority |
|-----------|------------|----------|
| cpu-high | -20 | Highest (most favorable) |
| cpu-low | 19 | Lowest (least favorable) |

PID NI COMMAND %CPU
4603 -20 cpu_hog 116
4608 19 cpu_hog 0.8

**Analysis:**
The Linux Completely Fair Scheduler (CFS) uses nice values to calculate process weight. Higher priority (lower nice value) receives exponentially more CPU time. The high-priority process received ~99% of CPU time while the low-priority process received ~1%, demonstrating effective priority enforcement.

**Linux scheduling goals demonstrated:**
- **Fairness**: Processes with same nice value receive equal CPU shares
- **Differentiation**: Different nice values produce proportional differences
- **Responsiveness**: Higher priority processes are scheduled more frequently

---

## Design Decisions and Tradeoffs

### Namespace Isolation
- **Decision**: Used `chroot()` instead of `pivot_root()`
- **Tradeoff**: Simpler but theoretically less secure
- **Justification**: Project scope doesn't require rootfs escape prevention

### Supervisor Architecture
- **Decision**: Single supervisor process managing all containers
- **Tradeoff**: Single point of failure
- **Justification**: Simpler coordination and state management

### Control IPC
- **Decision**: UNIX domain socket for CLI commands
- **Tradeoff**: Connection-oriented overhead
- **Justification**: Reliable, supports multiple clients

### Logging Pipeline
- **Decision**: Pipes with bounded buffer and condition variables
- **Tradeoff**: Producers/consumers can block
- **Justification**: Prevents data loss, natural flow control

### Kernel Memory Monitor
- **Decision**: Mutex instead of spinlock for list protection
- **Tradeoff**: Can sleep, higher overhead
- **Justification**: Timer callback may need to sleep

### Memory Policy
- **Decision**: Separate soft and hard limits
- **Tradeoff**: More complex policy
- **Justification**: Allows warning before termination

### Scheduling Experiment
- **Decision**: Used `nice` values only, not cgroup CPU shares
- **Tradeoff**: Simpler than full cgroup implementation
- **Justification**: Sufficient to demonstrate scheduler differentiation

---

## Scheduler Experiment Results

### Raw Data

**Experiment 1: Different nice values on same CPU core**
- High priority (nice -20): 116% CPU
- Low priority (nice 19): 0.8% CPU
- Ratio: ~145:1

**Experiment 2: Equal nice values**
- Both processes received approximately equal CPU shares (within 5% variation)

### Conclusion
The Linux CFS effectively enforces priority differences through the weight system. Nice values provide a clear mechanism for controlling CPU allocation, with exponential differences between priority levels. The container runtime successfully launches and manages processes with different scheduling parameters.

---

## CLI Command Reference

| Command | Description |
|---------|-------------|
| `./engine start <id> <rootfs> <command>` | Start container in background |
| `./engine run <id> <rootfs> <command>` | Start container and wait for exit |
| `./engine ps` | List all containers with metadata |
| `./engine logs <id>` | Display container logs |
| `./engine stop <id>` | Stop container gracefully |

### Optional Flags
- `--soft-mib N` : Soft memory limit in MB (default: 40)
- `--hard-mib N` : Hard memory limit in MB (default: 64)
- `--nice N` : CPU nice value (-20 to 19, default: 0)

---

## Screenshots

*(Refer to attached screenshot files)*
OS_JACKFRUIT_ss.pdf

1. **Multi-container supervision** - Two containers running under one supervisor
2. **Metadata tracking** - Output of `ps` command showing container metadata
3. **Bounded-buffer logging** - Log files with container output
4. **CLI and IPC** - CLI commands communicating with supervisor
5. **Soft-limit warning** - Kernel warning for memory limit violation
6. **Hard-limit enforcement** - Container killed after exceeding hard limit
7. **Scheduling experiment** - CPU-bound workloads with different nice values
8. **Clean teardown** - No zombie processes after shutdown

---

## Submission Date

April 2026


**Raw Results:**
