// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// BusyAPI namespaces; unrelated integrations removed.
#ifndef BUSYMARK_GTK_ACCENT_HOST_H_
#define BUSYMARK_GTK_ACCENT_HOST_H_
#include <flutter_linux/flutter_linux.h>

struct BusyApiGtkAccentHost;
BusyApiGtkAccentHost* busyapi_gtk_accent_host_new(FlView* view,
                                                  GtkWidget* window);
void busyapi_gtk_accent_host_free(BusyApiGtkAccentHost* host);
#endif  // BUSYMARK_GTK_ACCENT_HOST_H_
