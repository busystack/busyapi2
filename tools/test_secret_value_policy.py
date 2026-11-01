import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class SecretValuePolicyTest(unittest.TestCase):
    def test_explicit_empty_permission_preserves_native_byte_bounds(self):
        repository = Path(__file__).resolve().parents[1]
        source = r'''
#include "secret_key_policy.h"
#include "secret_value_policy.h"
#include <cassert>
#include <string>
int main() {
  using busyapi_secrets::is_allowed_value;
  assert(!is_allowed_value(nullptr));
  assert(!is_allowed_value(nullptr, true));
  assert(!is_allowed_value(""));
  assert(!is_allowed_value("", false));
  assert(is_allowed_value("", true));
  assert(is_allowed_value("synthetic-password:with-colon"));
  const std::string maximum(64 * 1024, 'x'), oversized(64 * 1024 + 1, 'x');
  assert(is_allowed_value(maximum.c_str()));
  assert(is_allowed_value(maximum.c_str(), true));
  assert(!is_allowed_value(oversized.c_str()));
  assert(!is_allowed_value(oversized.c_str(), true));
  assert(busyapi_secrets::is_allowed_key("busyapi.request.secret.123e4567-e89b-42d3-a456-426614174000"));
  assert(!busyapi_secrets::is_allowed_key("another-application-key"));
}
'''
        with tempfile.TemporaryDirectory(prefix='busyapi-secret-policy-') as directory:
            path = Path(directory)
            fixture = path / 'policy.cc'
            fixture.write_text(source)
            executable = path / 'policy'
            subprocess.run([*shlex.split(os.environ.get('CXX', 'c++')), '-std=c++17', '-Wall', '-Wextra', '-Werror', '-I', str(repository / 'linux/runner'), str(fixture), '-o', str(executable)], check=True, capture_output=True, text=True, timeout=30)
            subprocess.run([str(executable)], check=True, capture_output=True, text=True, timeout=5)


if __name__ == '__main__':
    unittest.main()
