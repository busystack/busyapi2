// Copyright 2026 BusyStack. Apache-2.0.
#include "documentation_runtime.h"
#include <gmodule.h>

extern "C" G_MODULE_EXPORT const BusyApiDocumentationRuntime* busyapi_documentation_runtime_v1() {
  static const BusyApiDocumentationRuntime api = {
      1, sizeof(BusyApiDocumentationRuntime),
      busyapi_documentation_window_new, busyapi_documentation_window_show,
      busyapi_documentation_window_close, busyapi_documentation_window_set_outdated,
      busyapi_documentation_window_get_window, busyapi_documentation_window_get_view};
  return &api;
}
