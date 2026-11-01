// Test-only syscall attempts. Never installed or linked into runtime assets.
#include <node_api.h>
#include <sys/syscall.h>
#include <sys/mman.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <linux/io_uring.h>
#include <linux/openat2.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <cerrno>
#include <cstring>

namespace {
napi_value attempt(napi_env env, napi_callback_info info) {
  napi_value argument, result;
  size_t count = 1, length = 0;
  char name[64];
  if (napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr) != napi_ok || count != 1 ||
      napi_get_value_string_utf8(env, argument, name, sizeof(name), &length) != napi_ok || length >= sizeof(name)) {
    napi_throw_error(env, "test.argument", "Choose a test attempt"); return nullptr;
  }
  errno = 0;
  long value = -1;
  if (!strcmp(name, "exec")) value = syscall(SYS_execve, "/bin/false", nullptr, nullptr);
  else if (!strcmp(name, "fork")) {
    value = syscall(SYS_fork);
    if (!value) _exit(77);
    if (value > 0) { int status = 0; waitpid(value, &status, 0); }
  } else if (!strcmp(name, "memfd")) value = syscall(SYS_memfd_create, "controlled-test", 0);
  else if (!strcmp(name, "io-uring")) { io_uring_params params{}; value = syscall(SYS_io_uring_setup, 1, &params); }
  else if (!strcmp(name, "ptrace")) value = syscall(SYS_ptrace, PTRACE_TRACEME, 0, nullptr, nullptr);
  else if (!strcmp(name, "process-memory")) value = syscall(SYS_process_vm_readv, getpid(), nullptr, 0, nullptr, 0, 0);
  else if (!strcmp(name, "ioctl")) { int bytes = 0; value = syscall(SYS_ioctl, 0, FIONREAD, &bytes); }
  else if (!strcmp(name, "kill")) value = syscall(SYS_kill, getpid(), 0);
  else if (!strcmp(name, "parent-signal")) value = syscall(SYS_tgkill, getppid(), getppid(), 0);
  else if (!strcmp(name, "filter")) value = syscall(SYS_seccomp, 0, 0, nullptr);
  else if (!strcmp(name, "openat2")) { open_how how{}; value = syscall(SYS_openat2, AT_FDCWD, "/etc/passwd", &how, sizeof(how)); }
  else if (!strcmp(name, "file-handle")) value = syscall(SYS_open_by_handle_at, AT_FDCWD, nullptr, O_RDONLY);
  else if (!strcmp(name, "pidfd")) value = syscall(SYS_pidfd_getfd, -1, 0, 0);
  else if (!strcmp(name, "splice")) value = syscall(SYS_splice, 0, nullptr, 1, nullptr, 1, 0);
  else if (!strcmp(name, "sendfile")) value = syscall(SYS_sendfile, 1, 0, nullptr, 1);
  else if (!strcmp(name, "executable-file")) value = reinterpret_cast<long>(mmap(nullptr, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, 0, 0));
  else if (!strcmp(name, "excessive-memory")) {
    void* memory = mmap(nullptr, 2ULL << 30, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    value = reinterpret_cast<long>(memory);
    if (memory != MAP_FAILED) munmap(memory, 2ULL << 30);
  }
  else { napi_throw_error(env, "test.argument", "Unknown test attempt"); return nullptr; }
  const int error = value < 0 ? errno : 0;
  if (value >= 0 && (!strcmp(name, "memfd") || !strcmp(name, "io-uring"))) close(value);
  napi_create_int32(env, error, &result);
  return result;
}
}
NAPI_MODULE_INIT() {
  napi_value method;
  napi_create_function(env, "attempt", NAPI_AUTO_LENGTH, attempt, nullptr, &method);
  napi_set_named_property(env, exports, "attempt", method);
  return exports;
}
