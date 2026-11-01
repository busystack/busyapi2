// Copyright 2026 BusyStack. Apache-2.0. No display or WebKit context is created.
#include "documentation_runtime.h"

#include <glib/gstdio.h>
#include <cstring>

int main(int argc, char** argv) {
  g_assert_cmpint(argc, >=, 2);
  const char* mode = argv[1];
  g_autoptr(GError) error = nullptr;
  const auto* api = busyapi_documentation_runtime_load(&error);
  if (std::strcmp(mode, "valid") == 0) {
    g_assert_no_error(error);
    g_assert_nonnull(api);
    g_assert_cmpuint(api->version, ==, 1);
    g_assert_cmpuint(api->size, ==, sizeof(BusyApiDocumentationRuntime));
    g_assert_true(api == busyapi_documentation_runtime_load(&error));
    g_assert_no_error(error);
    return 0;
  }
  const auto expected = std::strcmp(mode, "module") == 0 || std::strcmp(mode, "retry") == 0
      ? BUSYAPI_DOCUMENTATION_RUNTIME_MODULE
      : std::strcmp(mode, "load") == 0 ? BUSYAPI_DOCUMENTATION_RUNTIME_LOAD : BUSYAPI_DOCUMENTATION_RUNTIME_ABI;
  g_assert_null(api);
  g_assert_error(error, BUSYAPI_DOCUMENTATION_RUNTIME_ERROR, expected);
  g_assert_null(std::strstr(error->message, "/"));
  g_clear_error(&error);
  if (std::strcmp(mode, "retry") == 0) {
    g_assert_cmpint(argc, ==, 3);
    g_autofree gchar* executable = g_file_read_link("/proc/self/exe", &error);
    g_assert_no_error(error);
    g_autofree gchar* directory = g_path_get_dirname(executable);
    g_autofree gchar* target = g_build_filename(directory, "lib", "libbusyapi_documentation.so", nullptr);
    g_autofree gchar* bytes = nullptr;
    gsize length = 0;
    g_assert_true(g_file_get_contents(argv[2], &bytes, &length, &error));
    g_assert_no_error(error);
    g_assert_cmpuint(length, <, 4 * 1024 * 1024);
    g_assert_false(g_file_test(target, G_FILE_TEST_EXISTS));
    g_assert_true(g_file_set_contents(target, bytes, length, &error));
    g_assert_no_error(error);
    api = busyapi_documentation_runtime_load(&error);
    g_assert_no_error(error);
    g_assert_nonnull(api);
  }
  return 0;
}
