// BusyMark-derived GTK/WebKit lifecycle pattern, Copyright 2026 BusyStack.
// Apache-2.0. BusyAPI uses immutable supplied resources, not its visualization
// parser, rasterizer, Scalar integration or filesystem resource loader.
#ifndef BUSYAPI_DOCUMENTATION_WINDOW_H_
#define BUSYAPI_DOCUMENTATION_WINDOW_H_

#include <gtk/gtk.h>

typedef struct _WebKitWebView WebKitWebView;

G_BEGIN_DECLS

G_DECLARE_FINAL_TYPE(BusyApiDocumentationWindow, busyapi_documentation_window,
                    BUSYAPI, DOCUMENTATION_WINDOW, GObject)

// resources: flat, validated asset names -> immutable GBytes. The constructor
// takes its own references. No path, remote URI, project file or native command
// can be requested by a page. index.html is the sole top-level entry.
BusyApiDocumentationWindow* busyapi_documentation_window_new(
    GtkApplication* application, GtkWindow* parent, const gchar* title,
    const gchar* snapshot, GHashTable* resources, guint source_count,
    const gchar* loading_label, const gchar* failure_label, GError** error);

void busyapi_documentation_window_show(BusyApiDocumentationWindow* self);
void busyapi_documentation_window_close(BusyApiDocumentationWindow* self);

// Retain the captured document/reading position, but permanently revoke its
// source actions. Only a new capture/window can restore navigation authority.
gboolean busyapi_documentation_window_set_outdated(
    BusyApiDocumentationWindow* self, const gchar* localized_label);

// GTK ownership/access also permits native interaction tests without Flutter.
GtkWindow* busyapi_documentation_window_get_window(BusyApiDocumentationWindow* self);
WebKitWebView* busyapi_documentation_window_get_view(BusyApiDocumentationWindow* self);

// Signals: ready(); failed(static code); source-request(captured table index);
// closed(); blocked(static capability). Never emit authored URLs/source values.

G_END_DECLS
#endif
