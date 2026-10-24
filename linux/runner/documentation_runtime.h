// Copyright 2026 BusyStack. Apache-2.0.
// Fixed application-owned module ABI; no project/plugin discovery mechanism.
#ifndef BUSYAPI_DOCUMENTATION_RUNTIME_H_
#define BUSYAPI_DOCUMENTATION_RUNTIME_H_

#include "documentation_window.h"

G_BEGIN_DECLS

typedef struct {
  guint version;
  gsize size;
  BusyApiDocumentationWindow* (*create)(
      GtkApplication*, GtkWindow*, const gchar*, const gchar*, GHashTable*,
      guint, const gchar*, const gchar*, GError**);
  void (*show)(BusyApiDocumentationWindow*);
  void (*close)(BusyApiDocumentationWindow*);
  gboolean (*outdated)(BusyApiDocumentationWindow*, const gchar*);
  GtkWindow* (*window)(BusyApiDocumentationWindow*);
  WebKitWebView* (*view)(BusyApiDocumentationWindow*);
} BusyApiDocumentationRuntime;

typedef enum {
  BUSYAPI_DOCUMENTATION_RUNTIME_MODULE = 1,
  BUSYAPI_DOCUMENTATION_RUNTIME_LOAD = 2,
  BUSYAPI_DOCUMENTATION_RUNTIME_ABI = 3,
} BusyApiDocumentationRuntimeError;

#define BUSYAPI_DOCUMENTATION_RUNTIME_ERROR (g_quark_from_static_string("busyapi-documentation-runtime"))

// The executable's own lib/ directory is the sole module location. Failure is
// retryable; successful GType code remains resident without a hidden context.
const BusyApiDocumentationRuntime* busyapi_documentation_runtime_load(GError** error);

G_END_DECLS
#endif
