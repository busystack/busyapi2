// Copyright 2026 BusyStack. Apache-2.0.
// Generator-only startup policy. Does not change the governance launcher/seal.
#include <linux/landlock.h>
#include <seccomp.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <dlfcn.h>
#include <cstdlib>
#include <cerrno>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>
#include <filesystem>

namespace {
constexpr uint64_t kRead = LANDLOCK_ACCESS_FS_READ_FILE;
constexpr uint64_t kList = LANDLOCK_ACCESS_FS_READ_DIR;
constexpr uint64_t kExecute = LANDLOCK_ACCESS_FS_EXECUTE;
bool grant(int rules, const std::string& path, uint64_t rights) {
  int fd = open(path.c_str(), O_PATH | O_CLOEXEC);
  if (fd < 0) return false;
  landlock_path_beneath_attr rule{rights, fd};
  bool ok = !syscall(SYS_landlock_add_rule, rules, LANDLOCK_RULE_PATH_BENEATH, &rule, 0);
  close(fd);
  return ok;
}
}

int main(int argc, char** argv) {
  if (argc < 5 || argv[1][0] != '/' || argv[2][0] != '/' || argv[3][0] != '/') return 3;
  const auto* version = seccomp_version();
  if (version->major < 2 || (version->major == 2 &&
      (version->minor < 5 || (version->minor == 5 && version->micro < 5)))) return 2;
  const pid_t parent = getppid();
  if (parent <= 1 || prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) || getppid() != parent) return 2;
  if (setsid() < 0 && getpgrp() != getpid()) return 2;
  // No inherited application/keyring/resource descriptors cross this boundary.
  if (syscall(SYS_close_range, 3U, ~0U, 0U)) return 2;
  const rlimit fileLimit{64ULL * 1024 * 1024, 64ULL * 1024 * 1024};
  const rlimit coreLimit{0, 0};
  if (setrlimit(RLIMIT_FSIZE, &fileLimit) || setrlimit(RLIMIT_CORE, &coreLimit)) return 2;
  if (syscall(SYS_landlock_create_ruleset, nullptr, 0, 1) < 3) return 2;
  const uint64_t handled = (1ULL << 15) - 1;
  int rules = syscall(SYS_landlock_create_ruleset, &handled, sizeof(handled), 0);
  if (rules < 0) return 2;
  const std::string runtime(argv[1]), stage(argv[3]);
  const uint64_t kWrite = kRead | kList | LANDLOCK_ACCESS_FS_WRITE_FILE |
      LANDLOCK_ACCESS_FS_REMOVE_DIR | LANDLOCK_ACCESS_FS_REMOVE_FILE |
      LANDLOCK_ACCESS_FS_MAKE_DIR | LANDLOCK_ACCESS_FS_MAKE_REG |
      LANDLOCK_ACCESS_FS_REFER | LANDLOCK_ACCESS_FS_TRUNCATE;
  bool ok = grant(rules, runtime, kRead | kList | kExecute) &&
      grant(rules, argv[2], kRead) && grant(rules, stage, kWrite);
  // Preload exact JVM loader dependencies, then grant only mapped system DSOs.
  for (const char* name : {"libz.so.1", "libdl.so.2", "libpthread.so.0", "libm.so.6", "librt.so.1"})
    if (!dlopen(name, RTLD_NOW | RTLD_LOCAL)) ok = false;
  std::ifstream maps("/proc/self/maps");
  std::string line;
  if (!maps.is_open()) ok = false;
  while (ok && std::getline(maps, line)) {
    const auto start = line.find('/');
    if (start != std::string::npos) ok = grant(rules, line.substr(start), kRead | kExecute);
  }
  for (const char* file : {"/etc/ld.so.cache", "/dev/null", "/dev/urandom", "/dev/random",
                         "/proc/meminfo", "/proc/cpuinfo", "/proc/self/status", "/proc/self/stat"})
    if (!grant(rules, file, kRead)) ok = false;
  if (!ok || prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) ||
      syscall(SYS_landlock_restrict_self, rules, 0)) {
    std::fputs("Generator filesystem restriction unavailable\n", stderr);
    return 2;
  }
  close(rules);
  auto* filter = seccomp_init(SCMP_ACT_ALLOW);
  if (!filter) return 2;
  for (const char* name : {"socket", "connect", "bind", "listen", "accept", "accept4",
      "sendto", "sendmsg", "sendmmsg", "recvfrom", "recvmsg", "recvmmsg", "io_uring_setup",
      "io_uring_enter", "io_uring_register", "ptrace", "process_vm_readv", "process_vm_writev",
      "fork", "vfork", "unshare", "setns", "setsid", "setpgid"}) {
    int number = seccomp_syscall_resolve_name(name);
    if (number < 0 || seccomp_rule_add(filter, SCMP_ACT_ERRNO(EPERM), number, 0)) return 2;
  }
  // JVM FileDispatcherImpl uses an anonymous AF_UNIX pair for pre-close.
  // It cannot connect to a pathname/service; all external socket calls remain denied.
  if (seccomp_rule_add(filter, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(socketpair), 1,
      SCMP_A0(SCMP_CMP_NE, AF_UNIX, 0))) return 2;
  if (seccomp_load(filter)) return 2;
  seccomp_release(filter);
  if (clearenv() || setenv("LANG", "C.UTF-8", 1) ||
      setenv("TMPDIR", stage.c_str(), 1) || chdir(stage.c_str())) return 3;
  const auto libraries = (std::filesystem::path(runtime) / ".." / ".." / ".." / ".." / "lib").lexically_normal().string();
  if (setenv("LD_LIBRARY_PATH", libraries.c_str(), 1)) return 3;
  std::vector<std::string> command{runtime + "/bin/java", "-Xmx512m", "-XX:ActiveProcessorCount=2",
      "-XX:-UseContainerSupport", "-XX:-UsePerfData", "-XX:+DisableAttachMechanism",
      "-Djava.awt.headless=true", "-Djava.io.tmpdir=" + stage, "-Duser.home=" + stage,
      "-Duser.timezone=UTC", "-jar", argv[2]};
  command.insert(command.end() - 2, "-Dlogback.configurationFile=" + stage + "/.busyapi-logback.xml");
  for (int i = 4; i < argc; ++i) command.emplace_back(argv[i]);
  std::vector<char*> args;
  for (auto& value : command) args.push_back(value.data());
  args.push_back(nullptr);
  execv(args[0], args.data());
  std::fputs("Packaged Java runtime could not start\n", stderr);
  return 3;
}
