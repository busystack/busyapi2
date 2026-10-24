// Copyright 2026 BusyStack. Licensed under the Apache License, Version 2.0.
// Single-threaded stage: all future Node threads inherit this Landlock domain.
// Only trusted bootstrap files are readable here. Stage two seals ALL new file
// opens with seccomp TSYNC before any captured project code can be evaluated.
#include <seccomp.h>
#include <linux/landlock.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
#include <filesystem>
#include <fstream>
#include <string>
#include <dlfcn.h>
#include <vector>

namespace {
constexpr uint64_t kRead = 1ULL << 2, kReadDir = 1ULL << 3;
bool grantDescriptor(int rules, int fd, uint64_t rights) {
  const landlock_path_beneath_attr rule{rights, fd};
  return !syscall(SYS_landlock_add_rule, rules, LANDLOCK_RULE_PATH_BENEATH, &rule, 0);
}
bool grant(int rules, const std::string& path, uint64_t rights, bool optional = false) {
  const int fd = open(path.c_str(), O_PATH | O_CLOEXEC);
  if (fd < 0) return optional && errno == ENOENT;
  const bool ok = grantDescriptor(rules, fd, rights);
  close(fd);
  return ok;
}
bool landlock(const char* node, const char* entry) {
  // ABI 3 (Linux 6.2+) covers REFER and TRUNCATE. Later network/scoping/ioctl
  // rights are not prerequisites: inherited startup and final TSYNC seccomp
  // deny sockets, external signals and ioctl independently of Landlock's ABI.
  if (syscall(SYS_landlock_create_ruleset, nullptr, 0, 1) < 3) return false;
  const uint64_t handled = (1ULL << 15) - 1;
  const int rules = syscall(SYS_landlock_create_ruleset, &handled, sizeof(handled), 0);
  if (rules < 0) return false;
  // procfs may recreate an unpinned directory inode across exec/cache eviction.
  // The rule must keep addressing the SAME own-FD directory until inspection.
  // O_PATH grants no file data or directory enumeration through this fd. The
  // addon verifies its inode/flags and consumes it before project code runs.
  const int procPin = open("/proc/self/fd", O_PATH | O_DIRECTORY | O_CLOEXEC);
  bool ok = procPin >= 0 && grantDescriptor(rules, procPin, kReadDir) &&
      grant(rules, node, kRead | 1) &&
      grant(rules, std::filesystem::path(entry).parent_path().string(), kRead | kReadDir) &&
      grant(rules, "/etc/ld.so.cache", kRead, true) &&
      grant(rules, "/dev/null", kRead);
  // Explicit extra DT_NEEDED entries of the checksum-pinned Node 24.15.0 ELF.
  // On merged glibc these compatibility DSOs are not launcher dependencies.
  for (const char* name : {"libdl.so.2", "libpthread.so.0", "libm.so.6"})
    if (!dlopen(name, RTLD_NOW | RTLD_LOCAL)) ok = false;
  // The native launcher and Node use the same system ELF loader/C++ runtime.
  // Grant exact already-mapped DSOs, not a host /usr or library-directory tree.
  std::ifstream maps("/proc/self/maps");
  std::string line;
  if (!maps.is_open()) ok = false;
  while (ok && std::getline(maps, line)) {
    const auto start = line.find('/');
    if (start != std::string::npos) ok = grant(rules, line.substr(start), kRead | 1);
  }
  if (maps.bad()) ok = false;
  maps.close();
  if (ok) ok = !prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) &&
      !syscall(SYS_landlock_restrict_self, rules, 0);
  if (ok) ok = !fcntl(procPin, F_SETFD, 0);
  if (!ok && procPin >= 0) close(procPin);
  close(rules);
  return ok;
}
}

int main(int argc, char** argv) {
  if (argc < 3 || argv[1][0] != '/' || argv[argc-1][0] != '/') return 3;
  const auto* version = seccomp_version();
  if (version->major < 2 || (version->major == 2 &&
      (version->minor < 5 || (version->minor == 5 && version->micro < 5)))) return 2;
  const pid_t parent = getppid();
  if (parent <= 1 || prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) || getppid() != parent) return 2;
  // Never inherit NODE_OPTIONS, loader/preload paths, credentials, proxies or
  // vendor telemetry settings. Only the fixed packaged native-library directory
  // is carried through exec; the trusted Node entry clears it before code runs.
  if (clearenv()) return 3;
  const std::string libraries = (std::filesystem::path(argv[1]).parent_path() /
      ".." / ".." / "lib").lexically_normal().string();
  if (setenv("LD_LIBRARY_PATH", libraries.c_str(), 1)) return 3;
  auto* filter = seccomp_init(SCMP_ACT_ALLOW);
  if (!filter) return 2;
  int result = 0;
  for (const char* name : {"io_uring_setup", "io_uring_enter", "io_uring_register",
      "socket", "socketpair", "connect", "bind", "listen", "accept", "accept4",
      "sendto", "sendmsg", "sendmmsg", "recvfrom", "recvmsg", "recvmmsg"}) {
    const int number = seccomp_syscall_resolve_name(name);
    if (number < 0 || seccomp_rule_add(filter, SCMP_ACT_ERRNO(EPERM), number, 0)) result = 2;
  }
  if (!result && seccomp_load(filter)) result = 2;
  seccomp_release(filter);
  if (!result && !landlock(argv[1], argv[argc-1])) result = 2;
  if (result) {
    std::fputs("Required governance startup restriction is unavailable\n", stderr);
    return result;
  }
  // No ambient OpenSSL configuration/provider code is a bootstrap input.
  std::vector<char*> command{argv[1], const_cast<char*>("--openssl-config=/dev/null")};
  for (int index = 2; index < argc; ++index) command.push_back(argv[index]);
  command.push_back(nullptr);
  execv(argv[1], command.data());
  std::fputs("Cannot start the packaged governance runtime\n", stderr);
  return 3;
}
