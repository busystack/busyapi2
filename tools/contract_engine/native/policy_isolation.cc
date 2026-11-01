// Copyright 2026 BusyStack. Licensed under the Apache License, Version 2.0.
// Process-local restrictions for explicitly approved governance execution.
// No host policy, input-method component, namespace or desktop state is changed.
#include <node_api.h>
#include <seccomp.h>
#include <linux/landlock.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/mman.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <signal.h>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <utility>

#if !defined(__linux__) || !defined(__x86_64__)
#error The reviewed governance profile targets Linux amd64 only.
#endif

namespace {
constexpr int kMinimumAbi = 3;
bool installed = false;

struct Descriptor {
  int value;
  explicit Descriptor(int fd) : value(fd) {}
  ~Descriptor() { if (value >= 0) close(value); }
  Descriptor(const Descriptor&) = delete;
};
struct Filter {
  scmp_filter_ctx value = seccomp_init(SCMP_ACT_ERRNO(EPERM));
  ~Filter() { if (value) seccomp_release(value); }
  bool allow(const char* name, const std::vector<scmp_arg_cmp>& args = {}) {
    const int number = seccomp_syscall_resolve_name(name);
    return number >= 0 && seccomp_rule_add_array(value, SCMP_ACT_ALLOW, number,
        static_cast<unsigned>(args.size()), args.data()) == 0;
  }
};
napi_value failure(napi_env env, const char* code) {
  // Do not echo paths, code, supplied values, errno strings or environment.
  napi_throw_error(env, code, "Required governance isolation is unavailable");
  return nullptr;
}
napi_value number(napi_env env, int value) {
  napi_value result;
  napi_create_int32(env, value, &result);
  return result;
}
napi_value capabilities(napi_env env, napi_callback_info) {
  napi_value result, text;
  napi_create_object(env, &result);
  const int abi = static_cast<int>(syscall(SYS_landlock_create_ruleset, nullptr, 0, 1));
  napi_set_named_property(env, result, "landlockAbi", number(env, abi));
  const auto* version = seccomp_version();
  const std::string spelling = std::to_string(version->major) + "." +
      std::to_string(version->minor) + "." + std::to_string(version->micro);
  napi_create_string_utf8(env, spelling.c_str(), spelling.size(), &text);
  napi_set_named_property(env, result, "libseccomp", text);
  napi_set_named_property(env, result, "profile", number(env, 2));
  return result;
}

bool limit(int resource, rlim_t soft, rlim_t hard) {
  rlimit before{};
  if (getrlimit(resource, &before)) return false;
  const rlimit next{soft < before.rlim_cur ? soft : before.rlim_cur,
      hard < before.rlim_max ? hard : before.rlim_max};
  return setrlimit(resource, &next) == 0;
}

bool inheritedDescriptorsSafe() {
  // No ring created before the filter, inherited network channel, open secret
  // or writable filesystem capability may survive the bootstrap. Stdio belongs
  // to the native owner's bounded protocol. Other libuv pipes/eventfds contain
  // no source/environment capabilities. The owner starts with close-on-exec FDs.
  DIR* listing = opendir("/proc/self/fd");
  if (!listing) return false;
  const int listingFd = dirfd(listing);
  struct stat directory{};
  if (fstat(listingFd, &directory)) { closedir(listing); return false; }
  int procPin = -1;
  bool safe = true;
  while (const dirent* entry = readdir(listing)) {
    char* end = nullptr;
    const long fd = strtol(entry->d_name, &end, 10);
    if (!end || *end || fd < 0 || fd <= 2 || fd == listingFd) continue;
    struct stat metadata{};
    char target[512];
    const ssize_t length = readlinkat(listingFd, entry->d_name, target, sizeof(target));
    if (length < 0 || static_cast<size_t>(length) >= sizeof(target) || fstat(fd, &metadata)) { safe = false; break; }
    const std::string identity(target, static_cast<size_t>(length));
    if (S_ISDIR(metadata.st_mode) && metadata.st_dev == directory.st_dev &&
        metadata.st_ino == directory.st_ino &&
        identity == "/proc/" + std::to_string(getpid()) + "/fd" &&
        fcntl(fd, F_GETFL) == (O_PATH | O_DIRECTORY)) {
      if (procPin >= 0) { safe = false; break; }
      procPin = fd;
      continue;
    }
    if (identity == "anon_inode:[eventpoll]" || identity == "anon_inode:[eventfd]" ||
        S_ISFIFO(metadata.st_mode) || identity == "/dev/null") continue;
    safe = false;
    break;
  }
  // Exactly one launcher-owned O_PATH pin, not an arbitrary readable directory
  // capability. It must not survive into captured-code execution. Keeping the
  // listing open until after consumption also retains the procfs inode.
  if (procPin < 0 || close(procPin)) safe = false;
  closedir(listing);
  return safe;
}

napi_value restrict(napi_env env, napi_callback_info info) {
  if (installed) return failure(env, "policy.isolation.already-installed");
  size_t argc = 2;
  napi_value args[2];
  int32_t parent = 0;
  uint32_t count = 0;
  bool array = false;
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2 ||
      napi_is_array(env, args[0], &array) != napi_ok || !array ||
      napi_get_array_length(env, args[0], &count) != napi_ok || count != 0 ||
      napi_get_value_int32(env, args[1], &parent) != napi_ok || parent <= 1 || getppid() != parent)
    return failure(env, "policy.isolation.arguments");
  const auto* version = seccomp_version();
  if (version->major < 2 || (version->major == 2 &&
      (version->minor < 5 || (version->minor == 5 && version->micro < 5))))
    return failure(env, "policy.isolation.libseccomp");
  if (syscall(SYS_landlock_create_ruleset, nullptr, 0, 1) < kMinimumAbi)
    return failure(env, "policy.isolation.landlock-abi");
  if (!inheritedDescriptorsSafe()) return failure(env, "policy.isolation.inherited-descriptor");

  // Additional empty main-thread layer; the launcher's inherited domain already
  // covers every thread. The final TSYNC filter removes ALL open/reopen APIs
  // from every existing thread, including reads of trusted bootstrap assets.
  const uint64_t attributes = (1ULL << 15) - 1;
  Descriptor rules(static_cast<int>(syscall(SYS_landlock_create_ruleset,
      &attributes, sizeof(attributes), 0)));
  if (rules.value < 0) return failure(env, "policy.isolation.ruleset");
  Filter filter;
  if (!filter.value || seccomp_attr_set(filter.value, SCMP_FLTATR_CTL_TSYNC, 1) ||
      seccomp_attr_set(filter.value, SCMP_FLTATR_ACT_BADARCH, SCMP_ACT_KILL_PROCESS))
    return failure(env, "policy.isolation.filter");
  // libseccomp emits the architecture guard, rejects x32 and defaults unknown
  // and future syscalls to EPERM. No handwritten BPF or permissive denylist.
  for (const char* name : {"read", "readv", "pread64", "write", "writev", "close",
      "fstat", "newfstatat", "statx", "stat", "lstat", "lseek",
      "brk", "munmap", "mprotect", "madvise", "mremap", "futex", "futex_waitv",
      "rt_sigaction", "rt_sigprocmask", "rt_sigreturn", "sigaltstack", "getpid",
      "getppid", "gettid", "getuid", "geteuid", "getgid", "getegid", "getrandom",
      "clock_gettime", "clock_getres", "gettimeofday", "nanosleep", "clock_nanosleep",
      "sched_yield", "sched_getaffinity", "getrusage", "times", "uname",
      "epoll_create1", "epoll_ctl", "epoll_wait", "epoll_pwait", "epoll_pwait2",
      "eventfd2", "poll", "ppoll", "select", "pselect6", "restart_syscall",
      "dup", "dup2", "dup3", "exit", "exit_group"}) {
    if (!filter.allow(name)) return failure(env, "policy.isolation.syscall");
  }
  // Anonymous memory is required by V8's JIT/heap, never new executable files
  // or native modules. Existing trusted Node/addon/libraries are loaded first.
  if (!filter.allow("mmap", {{3, SCMP_CMP_MASKED_EQ, MAP_ANONYMOUS, MAP_ANONYMOUS}}) ||
      !filter.allow("tgkill", {{0, SCMP_CMP_EQ, static_cast<uint64_t>(getpid()), 0}}))
    return failure(env, "policy.isolation.memory");
  for (const int command : {F_GETFD, F_SETFD, F_GETFL, F_SETFL})
    if (!filter.allow("fcntl", {{1, SCMP_CMP_EQ, static_cast<uint64_t>(command), 0}}))
      return failure(env, "policy.isolation.descriptor");

  // Only the dedicated, empty-environment child may call this entry. Limit
  // writes/core dumps/CPU, deny ptrace and kill it if its native owner dies.
  // The owner also bounds wall time/output and awaits actual process exit.
  if (!limit(RLIMIT_CORE, 0, 0) || !limit(RLIMIT_FSIZE, 0, 0) ||
      !limit(RLIMIT_CPU, 10, 12) || !limit(RLIMIT_NOFILE, 128, 128) ||
      !limit(RLIMIT_DATA, 1ULL << 30, 1ULL << 30) ||
      !limit(RLIMIT_AS, 3ULL << 30, 3ULL << 30) ||
      prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) ||
      prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) || getppid() != parent ||
      prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))
    return failure(env, "policy.isolation.process");
  // Order is intentional: no project code can run between either stage or on
  // failure. The bootstrap must exit on any exception, even after partial apply.
  if (syscall(SYS_landlock_restrict_self, rules.value, 0))
    return failure(env, "policy.isolation.landlock");
  if (seccomp_load(filter.value)) return failure(env, "policy.isolation.seccomp-tsync");
  installed = true;
  napi_value result;
  napi_get_boolean(env, true, &result);
  return result;
}
}  // namespace

NAPI_MODULE_INIT() {
  const std::pair<const char*, napi_callback> methods[] = {
      {"capabilities", capabilities}, {"restrict", restrict}};
  for (const auto& item : methods) {
    napi_value method;
    napi_create_function(env, item.first, NAPI_AUTO_LENGTH, item.second, nullptr, &method);
    napi_set_named_property(env, exports, item.first, method);
  }
  return exports;
}
