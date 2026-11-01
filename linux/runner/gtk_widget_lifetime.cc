#include "gtk_widget_lifetime.h"

namespace {

void release_widgets(gpointer data, GObject*) {
  g_ptr_array_unref(static_cast<GPtrArray*>(data));
}

void retain_child(GtkWidget* child, gpointer data) {
  g_ptr_array_add(static_cast<GPtrArray*>(data), g_object_ref(child));
}

}  // namespace

void busyapi_retain_widget_tree_until_disposed(GtkWidget* root, GObject* owner) {
  g_return_if_fail(GTK_IS_WIDGET(root));
  g_return_if_fail(G_IS_OBJECT(owner));

  GPtrArray* widgets = g_ptr_array_new_with_free_func(g_object_unref);
  g_ptr_array_add(widgets, g_object_ref(root));
  for (guint index = 0; index < widgets->len; index++) {
    GtkWidget* widget = GTK_WIDGET(g_ptr_array_index(widgets, index));
    if (!GTK_IS_CONTAINER(widget)) continue;
    gtk_container_forall(GTK_CONTAINER(widget), retain_child, widgets);
  }

  // GTK destroy recursively disposes children even when the root is retained.
  // Keep the renderer itself alive until FlEngine::dispose has joined raster
  // work. The pinned engine keeps its compositor until renderer finalization.
  g_object_weak_ref(owner, release_widgets, widgets);
}
