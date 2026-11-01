/* Copyright 2026 BusyStack. SPDX-License-Identifier: Apache-2.0
 * Compile the actual patched module with only its asynchronous transport
 * replaced by a controlled completion. No keyboard or IM is bypassed in the
 * native acceptance runs. Upstream source retains its LGPL notices. */
#define ibus_input_context_process_key_event_async controlled_async
#define ibus_input_context_process_key_event_async_finish controlled_finish
#define gdk_event_put observed_event_put
#include BUSYAPI_IBUS_SOURCE

static GAsyncReadyCallback pending_callback;
static gpointer pending_data;
static guint starts, finishes, forwards, native_puts;
static gpointer last_token;
static gboolean last_handled;

void controlled_async(IBusInputContext *context, guint32 keyval, guint32 keycode,
                      guint32 state, gint timeout, GCancellable *cancellable,
                      GAsyncReadyCallback callback, gpointer data)
{
    g_assert_null(pending_callback);
    pending_callback = callback;
    pending_data = data;
}

gboolean controlled_finish(IBusInputContext *context, GAsyncResult *result,
                            GError **error)
{
    return g_task_propagate_boolean(G_TASK(result), error);
}

void observed_event_put(const GdkEvent *event) { native_puts++; }

static gpointer start(GdkEvent *event)
{
    return GUINT_TO_POINTER(++starts);
}

static gboolean finish(gpointer token, GdkEvent *event, gboolean handled)
{
    finishes++;
    last_token = token;
    last_handled = handled;
    if (!handled) g_assert_true((event->key.state & IBUS_IGNORED_MASK) != 0);
    return TRUE;
}

static gboolean forward(gpointer token, GdkEvent *event)
{
    forwards++;
    last_token = token;
    return TRUE;
}

static void complete(gboolean handled)
{
    GAsyncReadyCallback callback = pending_callback;
    gpointer data = pending_data;
    pending_callback = NULL;
    pending_data = NULL;
    GTask *task = g_task_new(NULL, NULL, NULL, NULL);
    g_task_return_boolean(task, handled);
    callback(NULL, G_ASYNC_RESULT(task), data);
    g_object_unref(task);
}

/* Register the module's real dynamic GtkIMContext type. */
typedef struct { GTypeModule parent; } TestModule;
typedef struct { GTypeModuleClass parent; } TestModuleClass;
G_DEFINE_TYPE(TestModule, test_module, G_TYPE_TYPE_MODULE)
static gboolean module_load(GTypeModule *module)
{
    ibus_im_context_register_type(module);
    return TRUE;
}
static void module_unload(GTypeModule *module) {}
static void test_module_init(TestModule *module) {}
static void test_module_class_init(TestModuleClass *klass)
{
    G_TYPE_MODULE_CLASS(klass)->load = module_load;
    G_TYPE_MODULE_CLASS(klass)->unload = module_unload;
}

static IBusIMContext *context(void)
{
    return ibus_im_context_new();
}

static GdkEvent *event(void)
{
    GdkEvent *key = gdk_event_new(GDK_KEY_PRESS);
    key->key.keyval = GDK_KEY_x;
    key->key.hardware_keycode = 53;
    return key;
}

int main(int argc, char **argv)
{
    gtk_init(&argc, &argv);
    ibus_init();
    /* Avoid installing a global key snooper in this noninteractive unit test. */
    g_setenv("IBUS_DISABLE_SNOOPER", "1", TRUE);
    TestModule *module = g_object_new(test_module_get_type(), NULL);
    g_assert_true(g_type_module_use(G_TYPE_MODULE(module)));
    busyapi_ibus_set_key_completion(start, finish, forward);
    IBusIMContext *owner = context();
    GdkEvent *key = event();

    /* No-text handled completion is still a real boundary. */
    _process_key_event_async(NULL, GDK_KEY_x, 53, 0, key, owner);
    g_assert_cmpuint(starts, ==, 1);
    g_assert_cmpuint(finishes, ==, 0);
    complete(TRUE);
    g_assert_cmpuint(finishes, ==, 1);
    g_assert_true(last_handled);
    g_assert_cmpuint(native_puts, ==, 0);

    /* Unhandled forwarding is delegated once, after provider completion. */
    _process_key_event_async(NULL, GDK_KEY_x, 53, 0, key, owner);
    complete(FALSE);
    g_assert_cmpuint(finishes, ==, 2);
    g_assert_false(last_handled);
    g_assert_cmpuint(native_puts, ==, 0);

    /* Explicit signals use the captured request; they do not complete it. */
    _process_key_event_async(NULL, GDK_KEY_x, 53, 0, key, owner);
    _ibus_context_forward_key_event_cb(NULL, GDK_KEY_x, 45,
                                       IBUS_IGNORED_MASK, owner);
    g_assert_cmpuint(forwards, ==, 1);
    g_assert_cmpuint(GPOINTER_TO_UINT(last_token), ==, 3);
    g_assert_cmpuint(finishes, ==, 2);
    complete(TRUE);
    g_assert_cmpuint(finishes, ==, 3);

    /* Context-creation queue captures once; submission transfers the token. */
    busyapi_queue_event(key);
    gpointer captured = GUINT_TO_POINTER(starts);
    _process_key_event_async(NULL, GDK_KEY_x, 53, 0, key, owner);
    g_assert_cmpuint(starts, ==, 4);
    g_assert_cmpuint(g_hash_table_size(busyapi_queued), ==, 0);
    complete(TRUE);
    g_assert_true(last_token == captured);

    /* Queued cancellation resolves ownership without native publication. */
    GdkEvent *cancelled = event();
    busyapi_queue_event(cancelled);
    busyapi_free_queued(cancelled);
    g_assert_true(last_handled);
    g_assert_cmpuint(finishes, ==, 5);
    g_assert_cmpuint(native_puts, ==, 0);

    /* Provider completion after GtkIMContext destruction is safe. */
    _process_key_event_async(NULL, GDK_KEY_x, 53, 0, key, owner);
    g_object_unref(owner);
    complete(TRUE);
    g_assert_cmpuint(finishes, ==, 6);
    g_assert_null(pending_callback);
    gdk_event_free(key);
    g_print("Private IBus: 6 controlled async ownership cases passed\n");
    /* Dynamic GTypes intentionally keep their module resident until exit. */
    return 0;
}
