#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <dirent.h>

#include "monitor_ioctl.h"

#define STACK_SIZE (1024 * 1024)
#define CONTAINER_ID_LEN 32
#define CONTROL_PATH "/tmp/mini_runtime.sock"
#define LOG_DIR "logs"
#define CONTROL_MESSAGE_LEN 256
#define CHILD_COMMAND_LEN 256
#define LOG_CHUNK_SIZE 4096
#define LOG_BUFFER_CAPACITY 16
#define DEFAULT_SOFT_LIMIT (40UL << 20)
#define DEFAULT_HARD_LIMIT (64UL << 20)

typedef enum {
    CMD_SUPERVISOR = 0,
    CMD_START,
    CMD_RUN,
    CMD_PS,
    CMD_LOGS,
    CMD_STOP
} command_kind_t;

typedef enum {
    CONTAINER_STARTING = 0,
    CONTAINER_RUNNING,
    CONTAINER_STOPPED,
    CONTAINER_KILLED,
    CONTAINER_EXITED
} container_state_t;

typedef struct container_record {
    char id[CONTAINER_ID_LEN];
    pid_t host_pid;
    time_t started_at;
    container_state_t state;
    unsigned long soft_limit_bytes;
    unsigned long hard_limit_bytes;
    int exit_code;
    int exit_signal;
    char log_path[PATH_MAX];
    int stop_requested;
    struct container_record *next;
} container_record_t;

typedef struct {
    char container_id[CONTAINER_ID_LEN];
    size_t length;
    char data[LOG_CHUNK_SIZE];
} log_item_t;

typedef struct {
    log_item_t items[LOG_BUFFER_CAPACITY];
    size_t head;
    size_t tail;
    size_t count;
    int shutting_down;
    pthread_mutex_t mutex;
    pthread_cond_t not_empty;
    pthread_cond_t not_full;
} bounded_buffer_t;

typedef struct {
    command_kind_t kind;
    char container_id[CONTAINER_ID_LEN];
    char rootfs[PATH_MAX];
    char command[CHILD_COMMAND_LEN];
    unsigned long soft_limit_bytes;
    unsigned long hard_limit_bytes;
    int nice_value;
} control_request_t;

typedef struct {
    int status;
    char message[CONTROL_MESSAGE_LEN];
} control_response_t;

typedef struct {
    char id[CONTAINER_ID_LEN];
    char rootfs[PATH_MAX];
    char command[CHILD_COMMAND_LEN];
    int nice_value;
    int log_write_fd;
    int monitor_fd;
    unsigned long soft_limit_bytes;
    unsigned long hard_limit_bytes;
} child_config_t;

typedef struct {
    int server_fd;
    int monitor_fd;
    int should_stop;
    pthread_t logger_thread;
    bounded_buffer_t log_buffer;
    pthread_mutex_t metadata_lock;
    container_record_t *containers;
} supervisor_ctx_t;

typedef struct {
    int pipe_fd;
    char container_id[CONTAINER_ID_LEN];
    bounded_buffer_t *buffer;
} pipe_reader_args_t;

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage:\n"
            "  %s supervisor <base-rootfs>\n"
            "  %s start <id> <container-rootfs> <command> [--soft-mib N] [--hard-mib N] [--nice N]\n"
            "  %s run <id> <container-rootfs> <command> [--soft-mib N] [--hard-mib N] [--nice N]\n"
            "  %s ps\n"
            "  %s logs <id>\n"
            "  %s stop <id>\n",
            prog, prog, prog, prog, prog, prog);
}

static int parse_mib_flag(const char *flag, const char *value, unsigned long *target_bytes)
{
    char *end = NULL;
    unsigned long mib;
    errno = 0;
    mib = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0') {
        fprintf(stderr, "Invalid value for %s: %s\n", flag, value);
        return -1;
    }
    if (mib > ULONG_MAX / (1UL << 20)) {
        fprintf(stderr, "Value for %s is too large: %s\n", flag, value);
        return -1;
    }
    *target_bytes = mib * (1UL << 20);
    return 0;
}

static int parse_optional_flags(control_request_t *req, int argc, char *argv[], int start_index)
{
    int i;
    for (i = start_index; i < argc; i += 2) {
        char *end = NULL;
        long nice_value;
        if (i + 1 >= argc) {
            fprintf(stderr, "Missing value for option: %s\n", argv[i]);
            return -1;
        }
        if (strcmp(argv[i], "--soft-mib") == 0) {
            if (parse_mib_flag("--soft-mib", argv[i + 1], &req->soft_limit_bytes) != 0)
                return -1;
            continue;
        }
        if (strcmp(argv[i], "--hard-mib") == 0) {
            if (parse_mib_flag("--hard-mib", argv[i + 1], &req->hard_limit_bytes) != 0)
                return -1;
            continue;
        }
        if (strcmp(argv[i], "--nice") == 0) {
            errno = 0;
            nice_value = strtol(argv[i + 1], &end, 10);
            if (errno != 0 || end == argv[i + 1] || *end != '\0' || nice_value < -20 || nice_value > 19) {
                fprintf(stderr, "Invalid value for --nice (expected -20..19): %s\n", argv[i + 1]);
                return -1;
            }
            req->nice_value = (int)nice_value;
            continue;
        }
        fprintf(stderr, "Unknown option: %s\n", argv[i]);
        return -1;
    }
    if (req->soft_limit_bytes > req->hard_limit_bytes) {
        fprintf(stderr, "Invalid limits: soft limit cannot exceed hard limit\n");
        return -1;
    }
    return 0;
}

static const char *state_to_string(container_state_t state)
{
    switch (state) {
    case CONTAINER_STARTING: return "starting";
    case CONTAINER_RUNNING: return "running";
    case CONTAINER_STOPPED: return "stopped";
    case CONTAINER_KILLED: return "killed";
    case CONTAINER_EXITED: return "exited";
    default: return "unknown";
    }
}

static int bounded_buffer_init(bounded_buffer_t *buffer)
{
    int rc;
    memset(buffer, 0, sizeof(*buffer));
    rc = pthread_mutex_init(&buffer->mutex, NULL);
    if (rc != 0) return rc;
    rc = pthread_cond_init(&buffer->not_empty, NULL);
    if (rc != 0) { pthread_mutex_destroy(&buffer->mutex); return rc; }
    rc = pthread_cond_init(&buffer->not_full, NULL);
    if (rc != 0) { pthread_cond_destroy(&buffer->not_empty); pthread_mutex_destroy(&buffer->mutex); return rc; }
    return 0;
}

static void bounded_buffer_destroy(bounded_buffer_t *buffer)
{
    pthread_cond_destroy(&buffer->not_full);
    pthread_cond_destroy(&buffer->not_empty);
    pthread_mutex_destroy(&buffer->mutex);
}

static void bounded_buffer_begin_shutdown(bounded_buffer_t *buffer)
{
    pthread_mutex_lock(&buffer->mutex);
    buffer->shutting_down = 1;
    pthread_cond_broadcast(&buffer->not_empty);
    pthread_cond_broadcast(&buffer->not_full);
    pthread_mutex_unlock(&buffer->mutex);
}

int bounded_buffer_push(bounded_buffer_t *buffer, const log_item_t *item)
{
    pthread_mutex_lock(&buffer->mutex);
    while (buffer->count == LOG_BUFFER_CAPACITY && !buffer->shutting_down) {
        pthread_cond_wait(&buffer->not_full, &buffer->mutex);
    }
    if (buffer->shutting_down) {
        pthread_mutex_unlock(&buffer->mutex);
        return -1;
    }
    buffer->items[buffer->tail] = *item;
    buffer->tail = (buffer->tail + 1) % LOG_BUFFER_CAPACITY;
    buffer->count++;
    pthread_cond_signal(&buffer->not_empty);
    pthread_mutex_unlock(&buffer->mutex);
    return 0;
}

int bounded_buffer_pop(bounded_buffer_t *buffer, log_item_t *item)
{
    pthread_mutex_lock(&buffer->mutex);
    while (buffer->count == 0 && !buffer->shutting_down) {
        pthread_cond_wait(&buffer->not_empty, &buffer->mutex);
    }
    if (buffer->shutting_down && buffer->count == 0) {
        pthread_mutex_unlock(&buffer->mutex);
        return -1;
    }
    *item = buffer->items[buffer->head];
    buffer->head = (buffer->head + 1) % LOG_BUFFER_CAPACITY;
    buffer->count--;
    pthread_cond_signal(&buffer->not_full);
    pthread_mutex_unlock(&buffer->mutex);
    return 0;
}

void *logging_thread(void *arg)
{
    supervisor_ctx_t *ctx = (supervisor_ctx_t *)arg;
    log_item_t item;
    FILE *log_file = NULL;
    char log_path[PATH_MAX];
    
    mkdir(LOG_DIR, 0755);
    
    while (1) {
        if (bounded_buffer_pop(&ctx->log_buffer, &item) != 0)
            break;
        
        snprintf(log_path, sizeof(log_path), "%s/%s.log", LOG_DIR, item.container_id);
        log_file = fopen(log_path, "a");
        if (log_file) {
            fwrite(item.data, 1, item.length, log_file);
            fclose(log_file);
            printf("[LOG] Wrote %zu bytes to %s\n", item.length, log_path);
        }
        // Also print to stdout for visibility
        fwrite(item.data, 1, item.length, stdout);
        fflush(stdout);
    }
    return NULL;
}

void *pipe_reader_thread(void *arg)
{
    pipe_reader_args_t *args = (pipe_reader_args_t *)arg;
    char buf[LOG_CHUNK_SIZE];
    ssize_t n;
    log_item_t item;
    
    while ((n = read(args->pipe_fd, buf, sizeof(buf))) > 0) {
        strncpy(item.container_id, args->container_id, sizeof(item.container_id) - 1);
        item.container_id[sizeof(item.container_id) - 1] = '\0';
        item.length = n;
        memcpy(item.data, buf, n);
        bounded_buffer_push(args->buffer, &item);
    }
    
    close(args->pipe_fd);
    free(args);
    return NULL;
}

int child_fn(void *arg)
{
    child_config_t *config = (child_config_t *)arg;
    
    if (config->nice_value != 0)
        nice(config->nice_value);
    
    if (unshare(CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUTS) == -1) {
        perror("unshare");
        return 1;
    }
    
    mount(NULL, "/", NULL, MS_PRIVATE | MS_REC, NULL);
    
    if (chroot(config->rootfs) != 0) {
        perror("chroot");
        return 1;
    }
    
    if (chdir("/") != 0) {
        perror("chdir");
        return 1;
    }
    
    if (mount("proc", "/proc", "proc", 0, NULL) != 0) {
        perror("mount proc");
        return 1;
    }
    
    if (dup2(config->log_write_fd, STDOUT_FILENO) == -1) {
        perror("dup2 stdout");
        return 1;
    }
    if (dup2(config->log_write_fd, STDERR_FILENO) == -1) {
        perror("dup2 stderr");
        return 1;
    }
    close(config->log_write_fd);
    
    char *argv[] = {config->command, NULL};
    char *envp[] = {"PATH=/bin:/sbin:/usr/bin:/usr/sbin", "HOME=/", "TERM=linux", NULL};
    
    execve(config->command, argv, envp);
    perror("execve");
    return 1;
}

int register_with_monitor(int monitor_fd, const char *container_id, pid_t host_pid,
                          unsigned long soft_limit_bytes, unsigned long hard_limit_bytes)
{
    struct monitor_request req;
    memset(&req, 0, sizeof(req));
    req.pid = host_pid;
    req.soft_limit_bytes = soft_limit_bytes;
    req.hard_limit_bytes = hard_limit_bytes;
    strncpy(req.container_id, container_id, sizeof(req.container_id) - 1);
    return ioctl(monitor_fd, MONITOR_REGISTER, &req);
}

int unregister_from_monitor(int monitor_fd, const char *container_id, pid_t host_pid)
{
    struct monitor_request req;
    memset(&req, 0, sizeof(req));
    req.pid = host_pid;
    strncpy(req.container_id, container_id, sizeof(req.container_id) - 1);
    return ioctl(monitor_fd, MONITOR_UNREGISTER, &req);
}

static container_record_t *find_container(supervisor_ctx_t *ctx, const char *id)
{
    container_record_t *curr = ctx->containers;
    while (curr) {
        if (strcmp(curr->id, id) == 0)
            return curr;
        curr = curr->next;
    }
    return NULL;
}

static void add_container(supervisor_ctx_t *ctx, container_record_t *record)
{
    record->next = ctx->containers;
    ctx->containers = record;
}

static int start_container(supervisor_ctx_t *ctx, control_request_t *req, control_response_t *resp)
{
    char stack[STACK_SIZE];
    int pipe_fd[2];
    pid_t child_pid;
    container_record_t *record;
    child_config_t config;
    pthread_t reader_thread;
    pipe_reader_args_t *reader_args;
    
    pthread_mutex_lock(&ctx->metadata_lock);
    
    if (find_container(ctx, req->container_id)) {
        snprintf(resp->message, sizeof(resp->message), "Container %s already exists", req->container_id);
        pthread_mutex_unlock(&ctx->metadata_lock);
        return -1;
    }
    
    if (pipe(pipe_fd) == -1) {
        snprintf(resp->message, sizeof(resp->message), "Pipe creation failed");
        pthread_mutex_unlock(&ctx->metadata_lock);
        return -1;
    }
    
    memset(&config, 0, sizeof(config));
    strncpy(config.id, req->container_id, sizeof(config.id) - 1);
    strncpy(config.rootfs, req->rootfs, sizeof(config.rootfs) - 1);
    strncpy(config.command, req->command, sizeof(config.command) - 1);
    config.nice_value = req->nice_value;
    config.log_write_fd = pipe_fd[1];
    config.monitor_fd = ctx->monitor_fd;
    config.soft_limit_bytes = req->soft_limit_bytes;
    config.hard_limit_bytes = req->hard_limit_bytes;
    
    child_pid = clone(child_fn, stack + STACK_SIZE, 
                      CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUTS | SIGCHLD,
                      &config);
    
    if (child_pid == -1) {
        snprintf(resp->message, sizeof(resp->message), "Clone failed: %s", strerror(errno));
        close(pipe_fd[0]);
        close(pipe_fd[1]);
        pthread_mutex_unlock(&ctx->metadata_lock);
        return -1;
    }
    
    close(pipe_fd[1]);
    
    record = calloc(1, sizeof(container_record_t));
    strncpy(record->id, req->container_id, sizeof(record->id) - 1);
    record->host_pid = child_pid;
    record->started_at = time(NULL);
    record->state = CONTAINER_RUNNING;
    record->soft_limit_bytes = req->soft_limit_bytes;
    record->hard_limit_bytes = req->hard_limit_bytes;
    record->stop_requested = 0;
    snprintf(record->log_path, sizeof(record->log_path), "%s/%s.log", LOG_DIR, req->container_id);
    add_container(ctx, record);
    
    pthread_mutex_unlock(&ctx->metadata_lock);
    
    register_with_monitor(ctx->monitor_fd, req->container_id, child_pid,
                          req->soft_limit_bytes, req->hard_limit_bytes);
    
    // Start thread to read from pipe
    reader_args = malloc(sizeof(pipe_reader_args_t));
    reader_args->pipe_fd = pipe_fd[0];
    strncpy(reader_args->container_id, req->container_id, sizeof(reader_args->container_id) - 1);
    reader_args->buffer = &ctx->log_buffer;
    
    pthread_create(&reader_thread, NULL, pipe_reader_thread, reader_args);
    pthread_detach(reader_thread);
    
    snprintf(resp->message, sizeof(resp->message), "Container %s started with PID %d", req->container_id, child_pid);
    return 0;
}

static int stop_container(supervisor_ctx_t *ctx, const char *id, control_response_t *resp)
{
    container_record_t *record;
    
    pthread_mutex_lock(&ctx->metadata_lock);
    record = find_container(ctx, id);
    
    if (!record) {
        snprintf(resp->message, sizeof(resp->message), "Container %s not found", id);
        pthread_mutex_unlock(&ctx->metadata_lock);
        return -1;
    }
    
    if (record->state != CONTAINER_RUNNING) {
        snprintf(resp->message, sizeof(resp->message), "Container %s is not running", id);
        pthread_mutex_unlock(&ctx->metadata_lock);
        return -1;
    }
    
    record->stop_requested = 1;
    kill(record->host_pid, SIGTERM);
    snprintf(resp->message, sizeof(resp->message), "Sent SIGTERM to container %s (PID %d)", id, record->host_pid);
    
    pthread_mutex_unlock(&ctx->metadata_lock);
    return 0;
}

static int list_containers(supervisor_ctx_t *ctx, control_response_t *resp)
{
    container_record_t *curr;
    char buffer[CONTROL_MESSAGE_LEN];
    int offset = 0;
    
    pthread_mutex_lock(&ctx->metadata_lock);
    
    offset += snprintf(buffer + offset, sizeof(buffer) - offset, "%-12s %-8s %-10s %-12s %s\n", 
                       "ID", "PID", "STATE", "SOFT(MB)", "HARD(MB)");
    
    curr = ctx->containers;
    while (curr && offset < sizeof(buffer) - 100) {
        offset += snprintf(buffer + offset, sizeof(buffer) - offset, "%-12s %-8d %-10s %-12lu %-12lu\n",
                          curr->id, curr->host_pid, state_to_string(curr->state),
                          curr->soft_limit_bytes >> 20, curr->hard_limit_bytes >> 20);
        curr = curr->next;
    }
    
    pthread_mutex_unlock(&ctx->metadata_lock);
    
    strncpy(resp->message, buffer, sizeof(resp->message) - 1);
    return 0;
}

static int show_logs(supervisor_ctx_t *ctx, const char *id, control_response_t *resp)
{
    char log_path[PATH_MAX];
    FILE *log_file;
    char line[256];
    char buffer[CONTROL_MESSAGE_LEN];
    int offset = 0;
    
    snprintf(log_path, sizeof(log_path), "%s/%s.log", LOG_DIR, id);
    log_file = fopen(log_path, "r");
    
    if (!log_file) {
        snprintf(resp->message, sizeof(resp->message), "No logs found for container %s", id);
        return -1;
    }
    
    buffer[0] = '\0';
    while (fgets(line, sizeof(line), log_file) && offset < sizeof(buffer) - 100) {
        offset += snprintf(buffer + offset, sizeof(buffer) - offset, "%s", line);
    }
    fclose(log_file);
    
    if (offset == 0)
        snprintf(buffer, sizeof(buffer), "(no output yet)");
    
    strncpy(resp->message, buffer, sizeof(resp->message) - 1);
    return 0;
}

static void reap_zombies(supervisor_ctx_t *ctx)
{
    int status;
    pid_t pid;
    container_record_t *curr;
    
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        pthread_mutex_lock(&ctx->metadata_lock);
        curr = ctx->containers;
        while (curr) {
            if (curr->host_pid == pid) {
                if (curr->stop_requested)
                    curr->state = CONTAINER_STOPPED;
                else if (WIFEXITED(status))
                    curr->state = CONTAINER_EXITED;
                else if (WIFSIGNALED(status))
                    curr->state =CONTAINER_KILLED;
                curr->exit_code = WEXITSTATUS(status);
                printf("[Supervisor] Container %s (PID %d) exited\n", curr->id, pid);
                unregister_from_monitor(ctx->monitor_fd, curr->id, pid);
                break;
            }
            curr = curr->next;
        }
        pthread_mutex_unlock(&ctx->metadata_lock);
    }
}

static int send_control_request(const control_request_t *req)
{
    int sock_fd;
    struct sockaddr_un addr;
    control_response_t resp;
    ssize_t n;
    
    sock_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock_fd < 0) {
        perror("socket");
        return 1;
    }
    
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, CONTROL_PATH, sizeof(addr.sun_path) - 1);
    
    if (connect(sock_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect (is supervisor running?)");
        close(sock_fd);
        return 1;
    }
    
    n = write(sock_fd, req, sizeof(control_request_t));
    if (n != sizeof(control_request_t)) {
        perror("write request");
        close(sock_fd);
        return 1;
    }
    
    n = read(sock_fd, &resp, sizeof(control_response_t));
    if (n <= 0) {
        perror("read response");
        close(sock_fd);
        return 1;
    }
    
    printf("%s\n", resp.message);
    close(sock_fd);
    return resp.status;
}

static int cmd_start(int argc, char *argv[])
{
    control_request_t req;
    if (argc < 5) {
        fprintf(stderr, "Usage: %s start <id> <container-rootfs> <command>\n", argv[0]);
        return 1;
    }
    memset(&req, 0, sizeof(req));
    req.kind = CMD_START;
    strncpy(req.container_id, argv[2], sizeof(req.container_id) - 1);
    strncpy(req.rootfs, argv[3], sizeof(req.rootfs) - 1);
    strncpy(req.command, argv[4], sizeof(req.command) - 1);
    req.soft_limit_bytes = DEFAULT_SOFT_LIMIT;
    req.hard_limit_bytes = DEFAULT_HARD_LIMIT;
    req.nice_value = 0;
    if (argc > 5 && parse_optional_flags(&req, argc, argv, 5) != 0)
        return 1;
    return send_control_request(&req);
}

static int cmd_run(int argc, char *argv[])
{
    control_request_t req;
    if (argc < 5) {
        fprintf(stderr, "Usage: %s run <id> <container-rootfs> <command>\n", argv[0]);
        return 1;
    }
    memset(&req, 0, sizeof(req));
    req.kind = CMD_RUN;
    strncpy(req.container_id, argv[2], sizeof(req.container_id) - 1);
    strncpy(req.rootfs, argv[3], sizeof(req.rootfs) - 1);
    strncpy(req.command, argv[4], sizeof(req.command) - 1);
    req.soft_limit_bytes = DEFAULT_SOFT_LIMIT;
    req.hard_limit_bytes = DEFAULT_HARD_LIMIT;
    req.nice_value = 0;
    if (argc > 5 && parse_optional_flags(&req, argc, argv, 5) != 0)
        return 1;
    return send_control_request(&req);
}

static int cmd_ps(void)
{
    control_request_t req;
    memset(&req, 0, sizeof(req));
    req.kind = CMD_PS;
    return send_control_request(&req);
}

static int cmd_logs(int argc, char *argv[])
{
    control_request_t req;
    if (argc < 3) {
        fprintf(stderr, "Usage: %s logs <id>\n", argv[0]);
        return 1;
    }
    memset(&req, 0, sizeof(req));
    req.kind = CMD_LOGS;
    strncpy(req.container_id, argv[2], sizeof(req.container_id) - 1);
    return send_control_request(&req);
}

static int cmd_stop(int argc, char *argv[])
{
    control_request_t req;
    if (argc < 3) {
        fprintf(stderr, "Usage: %s stop <id>\n", argv[0]);
        return 1;
    }
    memset(&req, 0, sizeof(req));
    req.kind = CMD_STOP;
    strncpy(req.container_id, argv[2], sizeof(req.container_id) - 1);
    return send_control_request(&req);
}

static int run_supervisor(const char *rootfs)
{
    supervisor_ctx_t ctx;
    struct sockaddr_un addr;
    int client_fd;
    control_request_t req;
    control_response_t resp;
    fd_set read_fds;
    struct sigaction sa;
    
    (void)rootfs;
    
    memset(&ctx, 0, sizeof(ctx));
    ctx.server_fd = -1;
    ctx.monitor_fd = -1;
    ctx.should_stop = 0;
    ctx.containers = NULL;
    
    pthread_mutex_init(&ctx.metadata_lock, NULL);
    bounded_buffer_init(&ctx.log_buffer);
    
    ctx.monitor_fd = open("/dev/container_monitor", O_RDWR);
    if (ctx.monitor_fd < 0) {
        perror("open /dev/container_monitor");
        return 1;
    }
    
    ctx.server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (ctx.server_fd < 0) {
        perror("socket");
        close(ctx.monitor_fd);
        return 1;
    }
    
    unlink(CONTROL_PATH);
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, CONTROL_PATH, sizeof(addr.sun_path) - 1);
    
    if (bind(ctx.server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(ctx.server_fd);
        close(ctx.monitor_fd);
        return 1;
    }
    
    if (listen(ctx.server_fd, 5) < 0) {
        perror("listen");
        close(ctx.server_fd);
        close(ctx.monitor_fd);
        return 1;
    }
    
    pthread_create(&ctx.logger_thread, NULL, logging_thread, &ctx);
    
    printf("Supervisor running. Control socket: %s\n", CONTROL_PATH);
    
    sa.sa_handler = SIG_IGN;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGCHLD, &sa, NULL);
    
    while (!ctx.should_stop) {
        FD_ZERO(&read_fds);
        FD_SET(ctx.server_fd, &read_fds);
        
        struct timeval tv = {0, 100000};
        if (select(ctx.server_fd + 1, &read_fds, NULL, NULL, &tv) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        
        reap_zombies(&ctx);
        
        if (FD_ISSET(ctx.server_fd, &read_fds)) {
            client_fd = accept(ctx.server_fd, NULL, NULL);
            if (client_fd < 0) continue;
            
            if (read(client_fd, &req, sizeof(req)) == sizeof(req)) {
                memset(&resp, 0, sizeof(resp));
                resp.status = 0;
                
                switch (req.kind) {
                    case CMD_START:
                        start_container(&ctx, &req, &resp);
                        break;
                    case CMD_RUN:
                        start_container(&ctx, &req, &resp);
                        break;
                    case CMD_PS:
                        list_containers(&ctx, &resp);
                        break;
                    case CMD_LOGS:
                        show_logs(&ctx, req.container_id, &resp);
                        break;
                    case CMD_STOP:
                        stop_container(&ctx, req.container_id, &resp);
                        break;
                    default:
                        snprintf(resp.message, sizeof(resp.message), "Unknown command");
                        resp.status = 1;
                }
                write(client_fd, &resp, sizeof(resp));
            }
            close(client_fd);
        }
    }
    
    bounded_buffer_begin_shutdown(&ctx.log_buffer);
    pthread_join(ctx.logger_thread, NULL);
    bounded_buffer_destroy(&ctx.log_buffer);
    close(ctx.server_fd);
    close(ctx.monitor_fd);
    unlink(CONTROL_PATH);
    pthread_mutex_destroy(&ctx.metadata_lock);
    return 0;
}

int main(int argc, char *argv[])
{
    if (argc < 2) {
        usage(argv[0]);
        return 1;
    }
    if (strcmp(argv[1], "supervisor") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: %s supervisor <base-rootfs>\n", argv[0]);
            return 1;
        }
        return run_supervisor(argv[2]);
    }
    if (strcmp(argv[1], "start") == 0) return cmd_start(argc, argv);
    if (strcmp(argv[1], "run") == 0) return cmd_run(argc, argv);
    if (strcmp(argv[1], "ps") == 0) return cmd_ps();
    if (strcmp(argv[1], "logs") == 0) return cmd_logs(argc, argv);
    if (strcmp(argv[1], "stop") == 0) return cmd_stop(argc, argv);
    usage(argv[0]);
    return 1;
}
