// Passive development observer for the pinned Flutter GTK renderer. Build this
// into a temporary .so and preload only an owned benchmark application. It does
// not schedule frames, change priorities, or enter the packaged application.
#include <dlfcn.h>
#include <epoxy/gl.h>
#include <gtk/gtk.h>
#include <cstring>

namespace {
struct Observer {
  unsigned records = 0;
  gint64 draw_start = 0;
  gint64 gl_copy = 0;
  gint64 engine_mutex_wait = 0;
  gint64 gl_context = 0;
  int surface_type = -1;
  int clip_status = -1;
  cairo_matrix_t matrix{};
};
thread_local Observer* active = nullptr;

gboolean draw_start(GtkWidget*, cairo_t*, gpointer data) {
  auto* observer = static_cast<Observer*>(data);
  observer->draw_start = g_get_monotonic_time();
  observer->gl_copy = 0;
  observer->engine_mutex_wait = 0;
  observer->gl_context = 0;
  active = observer;
  return FALSE;
}

gboolean draw_finish(GtkWidget* widget, cairo_t*, gpointer data) {
  auto* observer = static_cast<Observer*>(data);
  active = nullptr;
  if (observer->records++ >= 10000) return FALSE;
  auto* clock = gtk_widget_get_frame_clock(widget);
  const gint64 now = g_get_monotonic_time();
  const gint64 frame_time = clock ? gdk_frame_clock_get_frame_time(clock) : -1;
  g_printerr("BUSYAPI_GTK_FRAME {\"version\":1,\"clockFrame\":%" G_GINT64_FORMAT
             ",\"clockFrameTimeMonotonicUs\":%" G_GINT64_FORMAT
             ",\"drawStartMonotonicUs\":%" G_GINT64_FORMAT
             ",\"drawFinishMonotonicUs\":%" G_GINT64_FORMAT
             ",\"gdkGlCopyUs\":%" G_GINT64_FORMAT
             ",\"engineMutexWaitUs\":%" G_GINT64_FORMAT
             ",\"gdkGlContextUs\":%" G_GINT64_FORMAT ",\"cairoSurfaceType\":%d"
             ",\"clipStatus\":%d,\"matrix\":[%g,%g,%g,%g,%g,%g]"
             ",\"wallUs\":%" G_GINT64_FORMAT "}\n",
             clock ? gdk_frame_clock_get_frame_counter(clock) : -1,
             frame_time, observer->draw_start, now, observer->gl_copy,
             observer->engine_mutex_wait, observer->gl_context,
             observer->surface_type, observer->clip_status, observer->matrix.xx,
             observer->matrix.yx, observer->matrix.xy, observer->matrix.yy,
             observer->matrix.x0, observer->matrix.y0, g_get_real_time());
  return FALSE;
}
}  // namespace

// Count blocking at engine-owned mutex calls made by the active GTK draw.
// Raster-thread locks and unrelated GTK/GLib locks are not attributed to it.
// Forward the lock unchanged; this observer never changes lock ownership.
extern "C" void g_mutex_lock(GMutex* mutex) {
  using Lock = void (*)(GMutex*);
  static auto original = reinterpret_cast<Lock>(dlsym(RTLD_NEXT, "g_mutex_lock"));
  Dl_info caller{};
  bool observe = active && dladdr(__builtin_return_address(0), &caller) &&
                 caller.dli_fname;
  if (observe) {
    const char* slash = std::strrchr(caller.dli_fname, '/');
    observe = std::strcmp(slash ? slash + 1 : caller.dli_fname,
                          "libflutter_linux_gtk.so") == 0;
  }
  const gint64 start = observe ? g_get_monotonic_time() : 0;
  original(mutex);
  if (observe) active->engine_mutex_wait += g_get_monotonic_time() - start;
}

extern "C" void gdk_gl_context_make_current(GdkGLContext* context) {
  using MakeCurrent = void (*)(GdkGLContext*);
  static auto original = reinterpret_cast<MakeCurrent>(
      dlsym(RTLD_NEXT, "gdk_gl_context_make_current"));
  const gint64 start = active ? g_get_monotonic_time() : 0;
  original(context);
  if (active) active->gl_context += g_get_monotonic_time() - start;
}

extern "C" void gdk_gl_context_clear_current() {
  using ClearCurrent = void (*)();
  static auto original = reinterpret_cast<ClearCurrent>(
      dlsym(RTLD_NEXT, "gdk_gl_context_clear_current"));
  const gint64 start = active ? g_get_monotonic_time() : 0;
  original();
  if (active) active->gl_context += g_get_monotonic_time() - start;
}

// GTK can perform additional composition after FlView's draw returns. Keep
// that window-level interval distinct from Flutter raster and widget drawing.
extern "C" void gdk_window_end_draw_frame(GdkWindow* window,
                                           GdkDrawingContext* context) {
  using EndFrame = void (*)(GdkWindow*, GdkDrawingContext*);
  static auto original = reinterpret_cast<EndFrame>(
      dlsym(RTLD_NEXT, "gdk_window_end_draw_frame"));
  const gint64 start = g_get_monotonic_time();
  original(window, context);
  static unsigned records = 0;
  if (++records <= 10000)
    g_printerr("BUSYAPI_GTK_END_FRAME {\"version\":1,\"window\":\"%p\","
               "\"startMonotonicUs\":%" G_GINT64_FORMAT
               ",\"finishMonotonicUs\":%" G_GINT64_FORMAT
               ",\"wallUs\":%" G_GINT64_FORMAT "}\n",
               window, start, g_get_monotonic_time(), g_get_real_time());
}

extern "C" void gdk_cairo_draw_from_gl(cairo_t* cr, GdkWindow* window,
                                      int source, int source_type, int scale,
                                      int x, int y, int width, int height) {
  using Draw = void (*)(cairo_t*, GdkWindow*, int, int, int, int, int, int, int);
  static auto original = reinterpret_cast<Draw>(dlsym(RTLD_NEXT, "gdk_cairo_draw_from_gl"));
  static bool reported_gl = false;
  if (active && !reported_gl) {
    reported_gl = true;
    g_printerr("BUSYAPI_GTK_GL vendor=%s renderer=%s version=%s oes_egl_image=%d ext_egl_image_storage=%d\n",
               glGetString(GL_VENDOR), glGetString(GL_RENDERER),
               glGetString(GL_VERSION),
               epoxy_has_gl_extension("GL_OES_EGL_image"),
               epoxy_has_gl_extension("GL_EXT_EGL_image_storage"));
  }
  const gint64 start = active ? g_get_monotonic_time() : 0;
  if (active) {
    active->surface_type = cairo_surface_get_type(cairo_get_target(cr));
    auto* rectangles = cairo_copy_clip_rectangle_list(cr);
    active->clip_status = rectangles->status;
    cairo_rectangle_list_destroy(rectangles);
    cairo_get_matrix(cr, &active->matrix);
  }
  original(cr, window, source, source_type, scale, x, y, width, height);
  if (active) active->gl_copy += g_get_monotonic_time() - start;
}

extern "C" void gtk_widget_realize(GtkWidget* widget) {
  using Realize = void (*)(GtkWidget*);
  static auto original = reinterpret_cast<Realize>(dlsym(RTLD_NEXT, "gtk_widget_realize"));
  original(widget);
  // FlView's container draw encloses the renderer's GTK/GL composition. Its
  // FALSE draw result permits the after handler (the renderer returns TRUE).
  if (std::strcmp(G_OBJECT_TYPE_NAME(widget), "FlView") != 0 ||
      g_object_get_data(G_OBJECT(widget), "busyapi-benchmark-observer")) return;
  auto* observer = new Observer();
  g_object_set_data_full(G_OBJECT(widget), "busyapi-benchmark-observer", observer,
                        [](gpointer data) { delete static_cast<Observer*>(data); });
  g_signal_connect(widget, "draw", G_CALLBACK(draw_start), observer);
  g_signal_connect_after(widget, "draw", G_CALLBACK(draw_finish), observer);
}

// The pinned embedder hands rendered frames to GTK through g_idle_add. Observe
// its queueing boundary separately from GTK drawing; do not call these IDs
// Flutter frame numbers or change the original source priority.
namespace {
struct PresentIdle {
  GSourceFunc callback;
  gpointer data;
  gint64 queued;
  unsigned sequence;
};
unsigned present_sequence = 0;
gboolean present_idle(gpointer data) {
  auto* idle = static_cast<PresentIdle*>(data);
  const gint64 start = g_get_monotonic_time();
  g_printerr("BUSYAPI_GTK_IDLE {\"version\":1,\"sequence\":%u,"
             "\"queuedMonotonicUs\":%" G_GINT64_FORMAT
             ",\"dispatchMonotonicUs\":%" G_GINT64_FORMAT
             ",\"wallUs\":%" G_GINT64_FORMAT "}\n",
             idle->sequence, idle->queued, start, g_get_real_time());
  const gboolean keep = idle->callback(idle->data);
  if (!keep) delete idle;
  return keep;
}
}  // namespace
extern "C" guint g_idle_add(GSourceFunc callback, gpointer data) {
  using Add = guint (*)(GSourceFunc, gpointer);
  static auto original = reinterpret_cast<Add>(dlsym(RTLD_NEXT, "g_idle_add"));
  Dl_info info{};
  // The pinned Linux source has only renderer/GObject-unref idle callbacks.
  // Other libraries' opaque data must never be interpreted as a GObject.
  if (data != nullptr && dladdr(reinterpret_cast<void*>(callback), &info) &&
      info.dli_fname && std::strstr(info.dli_fname, "libflutter_linux_gtk") &&
      std::strcmp(G_OBJECT_TYPE_NAME(data), "FlViewRenderer") == 0 &&
      present_sequence < 10000) {
    auto* idle = new PresentIdle{callback, data, g_get_monotonic_time(),
                                 ++present_sequence};
    return original(present_idle, idle);
  }
  return original(callback, data);
}
