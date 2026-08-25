#include "ruby.h"
#include "extconf.h"
#include "mountfd.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
# include <sched.h>
#endif

#ifdef __linux__
static int write_all(int fd, const void *data, size_t length)
{
    const char *cursor = data;
    while (length > 0) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        cursor += written;
        length -= (size_t)written;
    }
    return 0;
}

static int write_proc_file(pid_t pid, const char *name, const char *value)
{
    char path[64];
    int fd;
    snprintf(path, sizeof(path), "/proc/%ld/%s", (long)pid, name);
    fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    if (write_all(fd, value, strlen(value)) < 0) {
        int error = errno;
        close(fd);
        errno = error;
        return -1;
    }
    return close(fd);
}

static int run_map_helper(const char *program, pid_t pid, const char *mapping)
{
    char *copy = strdup(mapping), *saveptr, *token, pid_text[32];
    size_t count = 0, capacity = 16;
    char **arguments = malloc(capacity * sizeof(char *));
    pid_t helper;
    int status;
    if (!copy || !arguments) {
        free(copy); free(arguments); errno = ENOMEM; return -1;
    }

    snprintf(pid_text, sizeof(pid_text), "%ld", (long)pid);
    arguments[count++] = (char *)program;
    arguments[count++] = pid_text;
    token = strtok_r(copy, " \t\r\n", &saveptr);
    while (token) {
        if (count + 1 == capacity) {
            capacity *= 2;
            char **grown = realloc(arguments, capacity * sizeof(char *));
            if (!grown) { free(arguments); free(copy); errno = ENOMEM; return -1; }
            arguments = grown;
        }
        arguments[count++] = token;
        token = strtok_r(NULL, " \t\r\n", &saveptr);
    }
    arguments[count] = NULL;

    helper = fork();
    if (helper == 0) {
        execvp(program, arguments);
        _exit(127);
    }
    if (helper < 0 || waitpid(helper, &status, 0) < 0) {
        int error = errno;
        free(arguments); free(copy); errno = error; return -1;
    }
    free(arguments); free(copy);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) { errno = EPERM; return -1; }
    return 0;
}

static int configure_maps(pid_t pid, const char *uid_map, const char *gid_map, int helper)
{
    if (helper) {
        if (run_map_helper("newuidmap", pid, uid_map) < 0) return -1;
        if (write_proc_file(pid, "setgroups", "deny") < 0 && errno != ENOENT && errno != EPERM)
            return -1;
        return run_map_helper("newgidmap", pid, gid_map);
    }

    if (write_proc_file(pid, "uid_map", uid_map) < 0) return -1;
    if (write_proc_file(pid, "setgroups", "deny") < 0 && errno != ENOENT && errno != EPERM)
        return -1;
    return write_proc_file(pid, "gid_map", gid_map);
}

static void stop_keeper(pid_t pid, int release_fd)
{
    char byte = 0;
    if (release_fd >= 0) {
        write_all(release_fd, &byte, 1);
        close(release_fd);
    } else {
        kill(pid, SIGKILL);
    }
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
}
#endif

static VALUE native_open_handle(VALUE self, VALUE path)
{
#ifdef __linux__
    int fd = open(StringValueCStr(path), O_RDONLY | O_CLOEXEC);
    if (fd < 0) rb_sys_fail_str(path);
    return mountfd_wrap_fd(fd);
#else
    VALUE mountfd = rb_const_get(rb_cObject, rb_intern("Mountfd"));
    VALUE error = rb_const_get(mountfd, rb_intern("UnsupportedError"));
    rb_raise(error, "user namespaces are unavailable on this platform");
#endif
}

static VALUE native_user_namespace(VALUE self, VALUE uid_value, VALUE gid_value, VALUE helper_value)
{
#ifdef __linux__
    const char *uid_map = StringValueCStr(uid_value);
    const char *gid_map = StringValueCStr(gid_value);
    int ready[2], release[2], child_error = 0, namespace_fd = -1;
    pid_t pid;
    char path[64], byte;
    ssize_t length;

    if (pipe2(ready, O_CLOEXEC) < 0) rb_sys_fail("pipe2");
    if (pipe2(release, O_CLOEXEC) < 0) {
        int error = errno;
        close(ready[0]); close(ready[1]); errno = error; rb_sys_fail("pipe2");
    }
    pid = fork();
    if (pid == 0) {
        close(ready[0]); close(release[1]);
        if (unshare(CLONE_NEWUSER) < 0) child_error = errno;
        write_all(ready[1], &child_error, sizeof(child_error));
        close(ready[1]);
        if (child_error == 0) while (read(release[0], &byte, 1) < 0 && errno == EINTR) {}
        _exit(child_error == 0 ? 0 : 1);
    }
    close(ready[1]); close(release[0]);
    if (pid < 0) {
        close(ready[0]); close(release[1]); rb_sys_fail("fork");
    }

    do { length = read(ready[0], &child_error, sizeof(child_error)); } while (length < 0 && errno == EINTR);
    close(ready[0]);
    if (length != sizeof(child_error) || child_error != 0) {
        int error = child_error ? child_error : EIO;
        stop_keeper(pid, -1); close(release[1]); errno = error;
        mountfd_syscall_failed("unshare(CLONE_NEWUSER)");
    }
    if (configure_maps(pid, uid_map, gid_map, RTEST(helper_value)) < 0) {
        int error = errno;
        stop_keeper(pid, -1); close(release[1]); errno = error; rb_sys_fail("configure user namespace maps");
    }
    snprintf(path, sizeof(path), "/proc/%ld/ns/user", (long)pid);
    namespace_fd = open(path, O_RDONLY | O_CLOEXEC);
    if (namespace_fd < 0) {
        int error = errno;
        stop_keeper(pid, -1); close(release[1]); errno = error; rb_sys_fail("open user namespace");
    }
    stop_keeper(pid, release[1]);
    return mountfd_wrap_fd(namespace_fd);
#else
    VALUE mountfd = rb_const_get(rb_cObject, rb_intern("Mountfd"));
    VALUE error = rb_const_get(mountfd, rb_intern("UnsupportedError"));
    rb_raise(error, "user namespaces are unavailable on this platform");
#endif
}

void mountfd_user_namespace_init(VALUE native)
{
    rb_define_singleton_method(native, "open_handle", native_open_handle, 1);
    rb_define_singleton_method(native, "user_namespace", native_user_namespace, 3);
}
