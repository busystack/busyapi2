#ifndef BUSYAPI_SECRET_KEY_POLICY_H_
#define BUSYAPI_SECRET_KEY_POLICY_H_

#include <cstring>

namespace busyapi_secrets {

constexpr char kPrefix[] = "busyapi.request.secret.";

// Contract text cannot select an arbitrary keyring entry. Only canonical v4
// UUIDs in BusyAPI's private request-secret namespace cross the native bridge.
inline bool is_allowed_key(const char* key) {
  if (key == nullptr ||
      std::strncmp(key, kPrefix, sizeof(kPrefix) - 1) != 0) {
    return false;
  }
  const char* id = key + sizeof(kPrefix) - 1;
  if (std::strlen(id) != 36 || id[14] != '4' ||
      (id[19] != '8' && id[19] != '9' && id[19] != 'a' && id[19] != 'b')) {
    return false;
  }
  for (unsigned int index = 0; index < 36; ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) {
      if (id[index] != '-') return false;
    } else if (!((id[index] >= '0' && id[index] <= '9') ||
                 (id[index] >= 'a' && id[index] <= 'f'))) {
      return false;
    }
  }
  return true;
}

}  // namespace busyapi_secrets

#endif  // BUSYAPI_SECRET_KEY_POLICY_H_
