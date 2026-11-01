#include "gtk_widget_lifetime.h"

struct LifetimeWidget {
  GtkDrawingArea parent;
  int* finalized;
};
struct LifetimeWidgetClass {
  GtkDrawingAreaClass parent;
};
G_DEFINE_TYPE(LifetimeWidget, lifetime_widget, GTK_TYPE_DRAWING_AREA)

static void lifetime_widget_finalize(GObject* object) {
  auto* widget = reinterpret_cast<LifetimeWidget*>(object);
  (*widget->finalized)++;
  G_OBJECT_CLASS(lifetime_widget_parent_class)->finalize(object);
}
static void lifetime_widget_class_init(LifetimeWidgetClass* klass) {
  G_OBJECT_CLASS(klass)->finalize = lifetime_widget_finalize;
}
static void lifetime_widget_init(LifetimeWidget*) {}

struct LifetimeOwner {
  GObject parent;
  int* widget_finalized;
  bool* disposed;
};
struct LifetimeOwnerClass {
  GObjectClass parent;
};
G_DEFINE_TYPE(LifetimeOwner, lifetime_owner, G_TYPE_OBJECT)

static void lifetime_owner_dispose(GObject* object) {
  auto* owner = reinterpret_cast<LifetimeOwner*>(object);
  // Represents the engine joining work that still uses the renderer.
  g_assert_cmpint(*owner->widget_finalized, ==, 0);
  *owner->disposed = true;
  G_OBJECT_CLASS(lifetime_owner_parent_class)->dispose(object);
}
static void lifetime_owner_class_init(LifetimeOwnerClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = lifetime_owner_dispose;
}
static void lifetime_owner_init(LifetimeOwner*) {}

static void nested_destroy_keeps_presentation_storage() {
  int finalized = 0;
  bool disposed = false;
  auto* owner = reinterpret_cast<LifetimeOwner*>(
      g_object_new(lifetime_owner_get_type(), nullptr));
  owner->widget_finalized = &finalized;
  owner->disposed = &disposed;
  GtkWidget* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  GtkWidget* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget* nested = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  auto* renderer = reinterpret_cast<LifetimeWidget*>(
      g_object_new(lifetime_widget_get_type(), nullptr));
  renderer->finalized = &finalized;
  gtk_container_add(GTK_CONTAINER(nested), GTK_WIDGET(renderer));
  gtk_container_add(GTK_CONTAINER(root), nested);
  gtk_container_add(GTK_CONTAINER(window), root);
  busyapi_retain_widget_tree_until_disposed(root, G_OBJECT(owner));

  gtk_widget_destroy(window);
  g_assert_false(disposed);
  g_assert_cmpint(finalized, ==, 0);
  g_object_unref(owner);
  g_assert_true(disposed);
  g_assert_cmpint(finalized, ==, 1);
}

static void owner_disposal_preserves_live_parent_ownership() {
  int finalized = 0;
  GtkWidget* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  auto* renderer = reinterpret_cast<LifetimeWidget*>(
      g_object_new(lifetime_widget_get_type(), nullptr));
  renderer->finalized = &finalized;
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(renderer));
  GObject* owner = G_OBJECT(g_object_new(G_TYPE_OBJECT, nullptr));
  busyapi_retain_widget_tree_until_disposed(GTK_WIDGET(renderer), owner);
  g_object_unref(owner);
  g_assert_cmpint(finalized, ==, 0);
  gtk_widget_destroy(window);
  g_assert_cmpint(finalized, ==, 1);
}

int main(int argc, char** argv) {
  gtk_test_init(&argc, &argv, nullptr);
  g_test_add_func("/busyapi/widget-lifetime/nested-destroy",
                  nested_destroy_keeps_presentation_storage);
  g_test_add_func("/busyapi/widget-lifetime/live-parent",
                  owner_disposal_preserves_live_parent_ownership);
  return g_test_run();
}
