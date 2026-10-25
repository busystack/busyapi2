#ifndef BUSYAPI_GTK_WIDGET_LIFETIME_H_
#define BUSYAPI_GTK_WIDGET_LIFETIME_H_

#include <gtk/gtk.h>

// Call on the GTK thread, which also owns disposal of owner. Destruction still
// disposes each widget normally; its storage survives until owner has disposed.
void busyapi_retain_widget_tree_until_disposed(GtkWidget* root, GObject* owner);

#endif  // BUSYAPI_GTK_WIDGET_LIFETIME_H_
