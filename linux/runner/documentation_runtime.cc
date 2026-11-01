// Copyright 2026 BusyStack. Apache-2.0.
// Optional documentation cannot prevent starting the native source workspace.
#include "documentation_runtime.h"

#include <gmodule.h>
#include <glib/gstdio.h>
#include <sys/stat.h>

const BusyApiDocumentationRuntime* busyapi_documentation_runtime_load(GError** error) {
  static const BusyApiDocumentationRuntime* loaded = nullptr;
  if (loaded) return loaded;
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree gchar* directory = executable ? g_path_get_dirname(executable) : nullptr;
  g_autofree gchar* path = directory ? g_build_filename(directory, "lib", "libbusyapi_documentation.so", nullptr) : nullptr;
  GStatBuf status;
  if (!path || g_lstat(path, &status) != 0 || !S_ISREG(status.st_mode)) {
    g_set_error_literal(error, BUSYAPI_DOCUMENTATION_RUNTIME_ERROR, BUSYAPI_DOCUMENTATION_RUNTIME_MODULE,
                        "The installed BusyAPI documentation module is unavailable");
    return nullptr;
  }
  // Resolve the complete native symbol table before publishing its API. A
  // missing runtime symbol must be an ordinary load error, not a later crash.
  auto* module = g_module_open(path, G_MODULE_BIND_LOCAL);
  if (!module) {
    // Do not expose native loader paths, environmental details or vendor text.
    g_set_error_literal(error, BUSYAPI_DOCUMENTATION_RUNTIME_ERROR, BUSYAPI_DOCUMENTATION_RUNTIME_LOAD,
                        "The native documentation runtime could not be loaded");
    return nullptr;
  }
  gpointer symbol = nullptr;
  const BusyApiDocumentationRuntime* api = nullptr;
  if (g_module_symbol(module, "busyapi_documentation_runtime_v1", &symbol) && symbol)
    api = reinterpret_cast<const BusyApiDocumentationRuntime* (*)()>(symbol)();
  if (!api || api->version != 1 || api->size != sizeof(BusyApiDocumentationRuntime) ||
      !api->create || !api->show || !api->close || !api->outdated || !api->window || !api->view) {
    g_module_close(module);
    g_set_error_literal(error, BUSYAPI_DOCUMENTATION_RUNTIME_ERROR, BUSYAPI_DOCUMENTATION_RUNTIME_ABI,
                        "The installed BusyAPI documentation module does not match the application");
    return nullptr;
  }
  // Registered GTypes retain class/function pointers after the last window.
  // Resident code is not a WebKit context or a background renderer process.
  g_module_make_resident(module);
  loaded = api;
  return loaded;
}
