#ifndef BUSYAPI_SECRET_VALUE_POLICY_H_
#define BUSYAPI_SECRET_VALUE_POLICY_H_

#include <cstddef>

namespace busyapi_secrets {

constexpr std::size_t kMaximumSecretBytes = 64 * 1024;

// Empty values require the credential editor's explicit scheme policy. The
// default bridge path retains its non-empty bound; all scans remain bounded.
inline bool is_allowed_value(const char* value, bool allow_empty = false) {
  if (value == nullptr) return false;
  std::size_t length = 0;
  while (length <= kMaximumSecretBytes && value[length] != '\0') ++length;
  return length <= kMaximumSecretBytes && (allow_empty || length > 0);
}

}  // namespace busyapi_secrets

#endif  // BUSYAPI_SECRET_VALUE_POLICY_H_
