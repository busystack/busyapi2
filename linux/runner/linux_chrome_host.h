// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// BusyAPI namespaces; unrelated integrations removed.
#ifndef RUNNER_LINUX_CHROME_HOST_H_
#define RUNNER_LINUX_CHROME_HOST_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

struct BusyApiLinuxChromeHost;
BusyApiLinuxChromeHost* busyapi_linux_chrome_host_new(
    FlView* view, GtkWindow* window, void (*set_theme)(gboolean));
void busyapi_linux_chrome_host_free(BusyApiLinuxChromeHost* host);

#endif
