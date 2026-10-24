// Test-only fault boundary. Not an application asset. No host policy changes.
#include <seccomp.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <cerrno>
#include <initializer_list>
int main(int argc, char** argv) {
  if (argc < 3 || strcmp(argv[1], "--deny-landlock")) return 3;
  auto* filter = seccomp_init(SCMP_ACT_ALLOW);
  if (!filter) return 3;
  bool ok = true;
  for (const char* name : {"landlock_create_ruleset", "landlock_add_rule", "landlock_restrict_self"}) {
    const int number = seccomp_syscall_resolve_name(name);
    if (number < 0 || seccomp_rule_add(filter, SCMP_ACT_ERRNO(ENOSYS), number, 0)) ok = false;
  }
  if (ok && seccomp_load(filter)) ok = false;
  seccomp_release(filter);
  if (!ok) return 3;
  execv(argv[2], argv + 2);
  return 3;
}
