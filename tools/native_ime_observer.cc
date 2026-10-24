// Copyright 2026 BusyStack. SPDX-License-Identifier: Apache-2.0
// Development-only passive GTK IM observer. Never linked into BusyAPI.
#include <dlfcn.h>
#include <gtk/gtk.h>
#include <stdio.h>

namespace {
unsigned records = 0;
void preedit(GtkIMContext* context, gpointer) {
  if (++records > 2000) return;
  gchar* text = nullptr;
  gint cursor = 0;
  gtk_im_context_get_preedit_string(context, &text, nullptr, &cursor);
  fprintf(stderr, "IME_OBSERVER phase=preedit mono_us=%" G_GINT64_FORMAT
                  " context=%p bytes=%zu cursor_characters=%d\n",
          g_get_monotonic_time(), context, text ? strlen(text) : 0, cursor);
  g_free(text);
}
void commit(GtkIMContext* context, const gchar* text, gpointer) {
  if (++records > 2000) return;
  fprintf(stderr, "IME_OBSERVER phase=commit mono_us=%" G_GINT64_FORMAT
                  " context=%p bytes=%zu\n",
          g_get_monotonic_time(), context, strlen(text));
}
}  // namespace

extern "C" GtkIMContext* gtk_im_multicontext_new() {
  auto real = reinterpret_cast<GtkIMContext* (*)()>(
      dlsym(RTLD_NEXT, "gtk_im_multicontext_new"));
  GtkIMContext* context = real();
  g_signal_connect(context, "preedit-changed", G_CALLBACK(preedit), nullptr);
  g_signal_connect(context, "commit", G_CALLBACK(commit), nullptr);
  return context;
}

extern "C" void gtk_im_context_set_cursor_location(
    GtkIMContext* context, const GdkRectangle* rect) {
  auto real = reinterpret_cast<void (*)(GtkIMContext*, const GdkRectangle*)>(
      dlsym(RTLD_NEXT, "gtk_im_context_set_cursor_location"));
  if (++records <= 2000) {
    fprintf(stderr, "IME_OBSERVER phase=cursor mono_us=%" G_GINT64_FORMAT
                    " context=%p kind=%s x=%d y=%d w=%d h=%d\n",
            g_get_monotonic_time(), context, G_OBJECT_TYPE_NAME(context),
            rect->x, rect->y, rect->width, rect->height);
  }
  real(context, rect);
}

// Opaque upstream type; keep this observer independent of IBus development
// headers and of any modified provider. Forward every original callback once.
struct _IBusInputContext;
using IBusInputContext = _IBusInputContext;
namespace {
struct AsyncRequest {
  GAsyncReadyCallback callback;
  gpointer data;
  unsigned sequence;
};
unsigned async_sequence = 0;
void async_reply(GObject* object, GAsyncResult* result, gpointer user_data) {
  auto request = static_cast<AsyncRequest*>(user_data);
  if (++records <= 2000)
    fprintf(stderr, "IME_OBSERVER phase=ibus-reply mono_us=%" G_GINT64_FORMAT
                    " request=%u\n", g_get_monotonic_time(), request->sequence);
  request->callback(object, result, request->data);
  delete request;
}
}  // namespace
extern "C" void ibus_input_context_process_key_event_async(
    IBusInputContext* context, guint32 value, guint32 code, guint32 state,
    gint timeout, GCancellable* cancellable, GAsyncReadyCallback callback,
    gpointer user_data) {
  using Function = void (*)(IBusInputContext*, guint32, guint32, guint32, gint,
                            GCancellable*, GAsyncReadyCallback, gpointer);
  static auto real = reinterpret_cast<Function>(
      dlsym(dlopen("libibus-1.0.so.5", RTLD_LAZY | RTLD_NOLOAD),
            "ibus_input_context_process_key_event_async"));
  const unsigned sequence = ++async_sequence;
  if (++records <= 2000)
    fprintf(stderr, "IME_OBSERVER phase=ibus-request mono_us=%" G_GINT64_FORMAT
                    " request=%u context=%p code=%u state=%u\n",
            g_get_monotonic_time(), sequence, context, code, state);
  if (callback == nullptr) {
    real(context, value, code, state, timeout, cancellable, callback, user_data);
  } else {
    auto request = new AsyncRequest{callback, user_data, sequence};
    real(context, value, code, state, timeout, cancellable, async_reply, request);
  }
}

// Observe the provider's public cursor API as well as GTK's entry point. GTK
// may bind its own internal calls locally, so neither interposition alone
// proves that the candidate service received an updated screen rectangle.
extern "C" void ibus_input_context_set_cursor_location(
    IBusInputContext* context, gint x, gint y, gint width, gint height) {
  using Function = void (*)(IBusInputContext*, gint, gint, gint, gint);
  static auto real = reinterpret_cast<Function>(
      dlsym(dlopen("libibus-1.0.so.5", RTLD_LAZY | RTLD_NOLOAD),
            "ibus_input_context_set_cursor_location"));
  if (++records <= 2000)
    fprintf(stderr, "IME_OBSERVER phase=ibus-cursor mono_us=%" G_GINT64_FORMAT
                    " context=%p x=%d y=%d w=%d h=%d\n",
            g_get_monotonic_time(), context, x, y, width, height);
  real(context, x, y, width, height);
}

// Existing provider synchronization modes are diagnosis only. Observing this
// API does not select a mode or change GTK's filtering/redispatch behavior.
extern "C" gboolean ibus_input_context_process_key_event(
    IBusInputContext* context, guint32 value, guint32 code, guint32 state) {
  using Function = gboolean (*)(IBusInputContext*, guint32, guint32, guint32);
  static auto real = reinterpret_cast<Function>(
      dlsym(dlopen("libibus-1.0.so.5", RTLD_LAZY | RTLD_NOLOAD),
            "ibus_input_context_process_key_event"));
  const gboolean result = real(context, value, code, state);
  if (++records <= 2000)
    fprintf(stderr, "IME_OBSERVER phase=ibus-sync mono_us=%" G_GINT64_FORMAT
                    " context=%p code=%u state=%u handled=%d\n",
            g_get_monotonic_time(), context, code, state, result);
  return result;
}
