// BusyMark-derived platform-channel lifecycle pattern, Copyright 2026 BusyStack.
// Apache-2.0. BusyAPI immutable documentation only; no visualization services.
#ifndef BUSYAPI_DOCUMENTATION_HOST_H_
#define BUSYAPI_DOCUMENTATION_HOST_H_
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

struct BusyApiDocumentationHost;
BusyApiDocumentationHost* busyapi_documentation_host_new(FlView* view,
                                                       GtkWindow* parent);
void busyapi_documentation_host_free(BusyApiDocumentationHost* host);
#endif
