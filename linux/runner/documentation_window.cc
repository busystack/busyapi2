// Adapted from BusyMark's separate GTK/WebKit reference-window pattern.
// Copyright 2026 BusyStack, Apache-2.0. BusyAPI-specific closed resource map,
// per-window ephemeral context, CSP/filter, narrow messages and cancellation.
#include "documentation_window.h"
#include <webkit2/webkit2.h>

#include <glib/gstdio.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

namespace {
constexpr char kEntry[] = "busyapi-doc://app/index.html";
constexpr char kScheme[] = "busyapi-doc";
constexpr gsize kResourceLimit = 16 * 1024 * 1024;
constexpr gsize kEntryLimit = 32 * 1024 * 1024;
constexpr gsize kTotalLimit = 128 * 1024 * 1024;
constexpr char kCsp[] =
    "default-src 'none'; script-src 'self'; "
    "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
    "font-src 'self' data:; connect-src 'self'; "
    "frame-src 'none'; object-src 'none'; worker-src 'none'; "
    "media-src 'none'; base-uri 'none'; form-action 'none'";
enum { kReady, kFailed, kSource, kClosed, kBlocked, kSignals };
guint signals[kSignals];
struct WindowData {
  GtkWidget* window = nullptr;
  GtkWidget* stack = nullptr;
  GtkWidget* status = nullptr;
  GtkWidget* outdated = nullptr;
  GtkWidget* outdated_label = nullptr;
  WebKitWebView* view = nullptr;
  WebKitWebContext* context = nullptr;
  WebKitUserContentManager* manager = nullptr;
  GCancellable* cancellation = nullptr;
  GHashTable* resources = nullptr;
  gchar* snapshot = nullptr;
  gchar* failure_label = nullptr;
  guint source_count = 0;
  guint timeout = 0;
  bool closed = false;
  bool failed = false;
  bool ready = false;
};
struct ResourceOwner {
  GWeakRef owner;
  GHashTable* resources;
};
const char* mime(const gchar* name) {
  if (g_str_has_suffix(name, ".html")) return "text/html; charset=utf-8";
  if (g_str_has_suffix(name, ".js") || g_str_has_suffix(name, ".mjs"))
    return "text/javascript; charset=utf-8";
  if (g_str_has_suffix(name, ".json")) return "application/json";
  if (g_str_has_suffix(name, ".css")) return "text/css; charset=utf-8";
  if (g_str_has_suffix(name, ".svg")) return "image/svg+xml";
  if (g_str_has_suffix(name, ".woff2")) return "font/woff2";
  if (g_str_has_suffix(name, ".woff")) return "font/woff";
  return "application/octet-stream";
}
bool valid_name(const char* name) {
  return name && std::strlen(name) <= 128 &&
      g_regex_match_simple("^[A-Za-z0-9_-]+\\.(html|mjs|js|json|css|svg|woff2?)$",
                           name, G_REGEX_OPTIMIZE, G_REGEX_MATCH_DEFAULT);
}
bool valid_snapshot(const char* value) {
  return value && std::strlen(value) <= 256 &&
      g_regex_match_simple("^[A-Za-z0-9._:-]+$", value,
                           G_REGEX_OPTIMIZE, G_REGEX_MATCH_DEFAULT);
}
bool entry_uri(const char* uri) {
  return uri && g_str_has_prefix(uri, kEntry) &&
      (uri[sizeof(kEntry) - 1] == '\0' || uri[sizeof(kEntry) - 1] == '#');
}
}  // namespace

struct _BusyApiDocumentationWindow { GObject parent_instance; WindowData* data; };
G_DEFINE_TYPE(BusyApiDocumentationWindow, busyapi_documentation_window, G_TYPE_OBJECT)

namespace {
void blocked(BusyApiDocumentationWindow* self, const char* capability) {
  if (!self->data->closed) g_signal_emit(self, signals[kBlocked], 0, capability);
}
void fail(BusyApiDocumentationWindow* self, const char* code) {
  auto* data = self->data;
  if (data->closed || data->failed) return;
  data->failed = true;
  if (data->timeout) { g_source_remove(data->timeout); data->timeout = 0; }
  g_cancellable_cancel(data->cancellation);
  if (data->view) {
    webkit_web_view_stop_loading(data->view);
    if(g_strcmp0(code,"busyapi.documentation.process-terminated")!=0)
      webkit_web_view_terminate_web_process(data->view);
  }
  gtk_label_set_text(GTK_LABEL(data->status), data->failure_label);
  gtk_widget_hide(GTK_WIDGET(data->view));
  gtk_widget_show(data->status);
  g_signal_emit(self, signals[kFailed], 0, code);
}
void resource_cb(WebKitURISchemeRequest* request, gpointer user_data) {
  auto* supplied = static_cast<ResourceOwner*>(user_data);
  g_autoptr(BusyApiDocumentationWindow) self = BUSYAPI_DOCUMENTATION_WINDOW(g_weak_ref_get(&supplied->owner));
  const char* uri = webkit_uri_scheme_request_get_uri(request);
  const char* path = webkit_uri_scheme_request_get_path(request);
  const char* method = webkit_uri_scheme_request_get_http_method(request);
  const char* name = path && path[0] == '/' ? path + 1 : nullptr;
  g_autofree gchar* expected = valid_name(name) ? g_strconcat("busyapi-doc://app/", name, nullptr) : nullptr;
  auto* bytes = expected && g_strcmp0(uri, expected) == 0 &&
      g_strcmp0(method, "GET") == 0 && self && !self->data->closed && !self->data->failed
      ? static_cast<GBytes*>(g_hash_table_lookup(supplied->resources, name)) : nullptr;
  if (!bytes) {
    if(self)blocked(self, "resource");
    g_autoptr(GError) error = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
                                                "busyapi.documentation.resource-denied");
    webkit_uri_scheme_request_finish_error(request, error);
    return;
  }
  g_autoptr(GInputStream) stream = g_memory_input_stream_new_from_bytes(bytes);
  g_autoptr(WebKitURISchemeResponse) response = webkit_uri_scheme_response_new(stream, g_bytes_get_size(bytes));
  webkit_uri_scheme_response_set_content_type(response, mime(name));
  SoupMessageHeaders* headers = soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
  // Keep the actual HTTP-header MIME identity alongside WebKit's response
  // property. Classic scripts' nosniff check consults the header itself.
  soup_message_headers_append(headers, "Content-Type", mime(name));
  soup_message_headers_append(headers, "Content-Security-Policy", kCsp);
  soup_message_headers_append(headers, "Cache-Control", "no-store");
  soup_message_headers_append(headers, "X-Content-Type-Options", "nosniff");
  soup_message_headers_append(headers, "Referrer-Policy", "no-referrer");
  soup_message_headers_append(headers, "X-DNS-Prefetch-Control", "off");
  // This setter takes full ownership (WebKitGTK 2.36+), not a borrowed ref.
  webkit_uri_scheme_response_set_http_headers(response, headers);
  webkit_uri_scheme_request_finish_with_response(request, response);
}
gboolean policy_cb(WebKitWebView*, WebKitPolicyDecision* decision,
                   WebKitPolicyDecisionType type, gpointer user_data) {
  auto* self = BUSYAPI_DOCUMENTATION_WINDOW(user_data);
  if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
    auto* action = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
    const char* uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
    if (entry_uri(uri) && !webkit_navigation_action_is_user_gesture(action)) return FALSE;
    // Hash links are internal documentation routes, not filesystem/URI access.
    if (entry_uri(uri) && std::strchr(uri, '#')) return FALSE;
  } else if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
    auto* response = WEBKIT_RESPONSE_POLICY_DECISION(decision);
    const char* uri = webkit_uri_response_get_uri(webkit_response_policy_decision_get_response(response));
    if (entry_uri(uri) && webkit_response_policy_decision_is_mime_type_supported(response)) return FALSE;
  }
  blocked(self, "navigation");
  webkit_policy_decision_ignore(decision);
  return TRUE;
}
gboolean permission_cb(WebKitWebView*, WebKitPermissionRequest* request, gpointer user_data) {
  webkit_permission_request_deny(request);blocked(BUSYAPI_DOCUMENTATION_WINDOW(user_data), "permission");return TRUE;
}
GtkWidget* create_cb(WebKitWebView*, WebKitNavigationAction*, gpointer user_data) {
  blocked(BUSYAPI_DOCUMENTATION_WINDOW(user_data), "popup");return nullptr;
}
gboolean context_menu_cb(WebKitWebView*, WebKitContextMenu*, GdkEvent*, WebKitHitTestResult*, gpointer) {
  return TRUE;  // No vendor/browser execution, download or external-open actions.
}
void download_cb(WebKitWebContext*, WebKitDownload* download, gpointer user_data) {
  webkit_download_cancel(download);blocked(BUSYAPI_DOCUMENTATION_WINDOW(user_data), "download");
}
gboolean load_failed_cb(WebKitWebView*, WebKitLoadEvent, const gchar*, GError*, gpointer user_data) {
  fail(BUSYAPI_DOCUMENTATION_WINDOW(user_data), "busyapi.documentation.load-failed");return TRUE;
}
void terminated_cb(WebKitWebView*, WebKitWebProcessTerminationReason, gpointer user_data) {
  fail(BUSYAPI_DOCUMENTATION_WINDOW(user_data), "busyapi.documentation.process-terminated");
}
bool message_string(JSCValue* object, const char* key, const char* expected) {
  g_autoptr(JSCValue) value = jsc_value_object_get_property(object, key);
  if (!jsc_value_is_string(value)) return false;
  g_autofree gchar* text = jsc_value_to_string(value);
  return g_strcmp0(text, expected) == 0;
}
void message_cb(WebKitUserContentManager*, WebKitJavascriptResult* result, gpointer user_data) {
  auto* self = BUSYAPI_DOCUMENTATION_WINDOW(user_data);auto* data = self->data;
  if (data->closed || data->failed || !entry_uri(webkit_web_view_get_uri(data->view))) return;
  JSCValue* object = webkit_javascript_result_get_js_value(result);
  if (!jsc_value_is_object(object) || jsc_value_is_array(object)) { blocked(self,"message");return; }
  g_auto(GStrv) keys = jsc_value_object_enumerate_properties(object);
  const guint count = keys ? g_strv_length(keys) : 0;
  if (count < 3 || count > 4 || !message_string(object,"snapshot",data->snapshot)) {blocked(self,"message");return;}
  g_autoptr(JSCValue) version = jsc_value_object_get_property(object,"version");
  if (!jsc_value_is_number(version) || jsc_value_to_double(version) != 1) {blocked(self,"message");return;}
  if (count == 3 && message_string(object,"kind","ready")) {
    if (!data->ready) {
      data->ready = true;
      if(data->timeout){g_source_remove(data->timeout);data->timeout=0;}
      gtk_widget_hide(data->status);
      gtk_widget_set_sensitive(GTK_WIDGET(data->view),TRUE);
      g_signal_emit(self,signals[kReady],0);
    }
    return;
  }
  if (count == 4 && message_string(object,"kind","source") && data->ready) {
    g_autoptr(JSCValue) index = jsc_value_object_get_property(object,"index");
    const double number = jsc_value_is_number(index) ? jsc_value_to_double(index) : -1;
    if (std::isfinite(number) && number >= 0 && number < data->source_count && std::floor(number) == number) {
      g_signal_emit(self,signals[kSource],0,static_cast<guint>(number));return;
    }
  }
  if (count == 4 && message_string(object,"kind","failed") && message_string(object,"code","renderer-failed")) {
    fail(self,"busyapi.documentation.renderer-failed");return;
  }
  blocked(self,"message");
}
void policy_message_cb(WebKitUserContentManager*, WebKitJavascriptResult* result, gpointer user_data) {
  auto* self=BUSYAPI_DOCUMENTATION_WINDOW(user_data);
  // This handler exists only in the native isolated policy world, never the
  // renderer's main JS world. No source URL/value crosses this audit channel.
  JSCValue* value=webkit_javascript_result_get_js_value(result);
  if(jsc_value_is_string(value)){
    g_autofree gchar* text=jsc_value_to_string(value);
    if(g_strcmp0(text,"resource")==0)blocked(self,"resource");
    else if(g_strcmp0(text,"navigation")==0)blocked(self,"navigation");
  }
}
gboolean timeout_cb(gpointer user_data) {
  auto* self = BUSYAPI_DOCUMENTATION_WINDOW(user_data);self->data->timeout=0;
  fail(self,"busyapi.documentation.timeout");return G_SOURCE_REMOVE;
}
void destroyed_cb(GtkWidget*, gpointer user_data) {
  auto* self = BUSYAPI_DOCUMENTATION_WINDOW(user_data);auto* data=self->data;
  if(data->closed)return;
  g_object_ref(self);  // A closed-signal owner may release its last handle.
  data->closed=true;
  if(data->timeout){g_source_remove(data->timeout);data->timeout=0;}
  g_cancellable_cancel(data->cancellation);
  if(data->view){webkit_web_view_stop_loading(data->view);g_signal_handlers_disconnect_by_data(data->view,self);}
  if(data->manager){webkit_user_content_manager_unregister_script_message_handler(data->manager,"busyapiDocumentation");g_signal_handlers_disconnect_by_data(data->manager,self);}
  if(data->manager)webkit_user_content_manager_unregister_script_message_handler_in_world(data->manager,"busyapiDocumentationPolicy","busyapi-policy");
  if(data->context)g_signal_handlers_disconnect_by_data(data->context,self);
  data->window=nullptr;data->view=nullptr;data->stack=nullptr;data->status=nullptr;
  // Closing releases the browser context/data even if a caller retains the
  // now-closed handle. In-flight streams own their own immutable GBytes refs.
  g_clear_object(&data->context);g_clear_object(&data->manager);
  g_clear_pointer(&data->resources,g_hash_table_unref);
  g_signal_emit(self,signals[kClosed],0);
  g_object_unref(self);
}
void filter_ready_cb(GObject* store, GAsyncResult* result, gpointer user_data) {
  g_autoptr(BusyApiDocumentationWindow) self = BUSYAPI_DOCUMENTATION_WINDOW(user_data);
  g_autoptr(GError) error = nullptr;
  WebKitUserContentFilter* filter = webkit_user_content_filter_store_save_finish(WEBKIT_USER_CONTENT_FILTER_STORE(store),result,&error);
  if (!self->data->closed && !self->data->failed) {
    if(!filter){fail(self,"busyapi.documentation.isolation-unavailable");}
    else {
      webkit_user_content_manager_add_filter(self->data->manager,filter);
      self->data->timeout=g_timeout_add_seconds(30,timeout_cb,self);
      webkit_web_view_load_uri(self->data->view,kEntry);
    }
  }
  if(filter)webkit_user_content_filter_unref(filter);
}
}  // namespace

void busyapi_documentation_window_close(BusyApiDocumentationWindow* self) {
  g_return_if_fail(BUSYAPI_IS_DOCUMENTATION_WINDOW(self));
  if(self->data->window)gtk_widget_destroy(self->data->window);
}
gboolean busyapi_documentation_window_set_outdated(
    BusyApiDocumentationWindow* self,const gchar* localized_label) {
  g_return_val_if_fail(BUSYAPI_IS_DOCUMENTATION_WINDOW(self),FALSE);
  auto* data=self->data;
  if(data->closed||data->failed||!localized_label||!localized_label[0]||
      std::strlen(localized_label)>4096||!g_utf8_validate(localized_label,-1,nullptr))return FALSE;
  data->source_count=0;
  gtk_label_set_text(GTK_LABEL(data->outdated_label),localized_label);
  gtk_widget_show(data->outdated);
  return TRUE;
}
GtkWindow* busyapi_documentation_window_get_window(BusyApiDocumentationWindow* self) {
  g_return_val_if_fail(BUSYAPI_IS_DOCUMENTATION_WINDOW(self),nullptr);
  return self->data->window?GTK_WINDOW(self->data->window):nullptr;
}
WebKitWebView* busyapi_documentation_window_get_view(BusyApiDocumentationWindow* self) {
  g_return_val_if_fail(BUSYAPI_IS_DOCUMENTATION_WINDOW(self),nullptr);return self->data->view;
}
void busyapi_documentation_window_show(BusyApiDocumentationWindow* self) {
  g_return_if_fail(BUSYAPI_IS_DOCUMENTATION_WINDOW(self));
  if(!self->data->closed&&self->data->window)gtk_widget_show_all(self->data->window);
}

BusyApiDocumentationWindow* busyapi_documentation_window_new(
    GtkApplication* application, GtkWindow* parent, const gchar* title,
    const gchar* snapshot, GHashTable* resources, guint source_count,
    const gchar* loading_label, const gchar* failure_label, GError** error) {
  if(!valid_snapshot(snapshot)||!resources||g_hash_table_size(resources)>64||source_count>200000||
      !title||!g_utf8_validate(title,-1,nullptr)||std::strlen(title)>4096||
      !loading_label||!failure_label||!loading_label[0]||!failure_label[0]||
      std::strlen(loading_label)>4096||std::strlen(failure_label)>4096||
      !g_utf8_validate(loading_label,-1,nullptr)||!g_utf8_validate(failure_label,-1,nullptr)) {
    g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_INVALID_ARGUMENT,"busyapi.documentation.arguments");return nullptr;
  }
  gsize total=0;GHashTableIter iterator;gpointer key,value;
  g_hash_table_iter_init(&iterator,resources);
  while(g_hash_table_iter_next(&iterator,&key,&value)){
    const gsize size=value?g_bytes_get_size(static_cast<GBytes*>(value)):0;
    const auto limit=key&&std::strcmp(static_cast<const char*>(key),"index.html")==0?kEntryLimit:kResourceLimit;
    if(!valid_name(static_cast<const char*>(key))||!value||size>limit||size>kTotalLimit-total){
      g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_INVALID_ARGUMENT,"busyapi.documentation.resource-limit");return nullptr;
    }
    total+=size;
  }
  if(!g_hash_table_contains(resources,"index.html")){
    g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_NOT_FOUND,"busyapi.documentation.entry-missing");return nullptr;
  }
  auto* self=BUSYAPI_DOCUMENTATION_WINDOW(g_object_new(busyapi_documentation_window_get_type(),nullptr));auto* data=self->data;
  data->snapshot=g_strdup(snapshot);data->source_count=source_count;data->failure_label=g_strdup(failure_label);
  data->resources=g_hash_table_new_full(g_str_hash,g_str_equal,g_free,reinterpret_cast<GDestroyNotify>(g_bytes_unref));
  g_hash_table_iter_init(&iterator,resources);while(g_hash_table_iter_next(&iterator,&key,&value))g_hash_table_insert(data->resources,g_strdup(static_cast<const char*>(key)),g_bytes_ref(static_cast<GBytes*>(value)));
  data->context=webkit_web_context_new_ephemeral();
  // Keep upstream sandboxing requested in every distribution. WebKitGTK
  // intentionally uses Snap confinement instead of nested Bubblewrap inside
  // Snap; this flag does not prove equivalent internal process isolation.
  // The closed loader, CSP/filter and narrow native-message policy below are
  // required in either environment. Qualify actual confined subprocesses,
  // never infer their boundary merely from SNAP environment variables.
  webkit_web_context_set_sandbox_enabled(data->context,TRUE);
  if(!webkit_web_context_get_sandbox_enabled(data->context)){
    g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_NOT_SUPPORTED,"busyapi.documentation.isolation-unavailable");g_object_unref(self);return nullptr;
  }
  webkit_web_context_set_cache_model(data->context,WEBKIT_CACHE_MODEL_DOCUMENT_VIEWER);
  webkit_web_context_set_spell_checking_enabled(data->context,FALSE);
  webkit_cookie_manager_set_accept_policy(webkit_web_context_get_cookie_manager(data->context),WEBKIT_COOKIE_POLICY_ACCEPT_NEVER);
  // WebKit may retain the context beyond window destruction. Its scheme loader
  // owns immutable bytes independently and only weakly observes the UI owner.
  auto* supplied=new ResourceOwner();g_weak_ref_init(&supplied->owner,self);supplied->resources=g_hash_table_ref(data->resources);
  webkit_web_context_register_uri_scheme(data->context,kScheme,resource_cb,supplied,[](gpointer value){
    auto* owned=static_cast<ResourceOwner*>(value);g_weak_ref_clear(&owned->owner);g_hash_table_unref(owned->resources);delete owned;
  });
  auto* security=webkit_web_context_get_security_manager(data->context);
  webkit_security_manager_register_uri_scheme_as_secure(security,kScheme);
  webkit_security_manager_register_uri_scheme_as_cors_enabled(security,kScheme);
  g_signal_connect(data->context,"download-started",G_CALLBACK(download_cb),self);
  data->manager=webkit_user_content_manager_new();
  g_signal_connect(data->manager,"script-message-received::busyapiDocumentation",G_CALLBACK(message_cb),self);
  webkit_user_content_manager_register_script_message_handler(data->manager,"busyapiDocumentation");
  g_signal_connect(data->manager,"script-message-received::busyapiDocumentationPolicy",G_CALLBACK(policy_message_cb),self);
  webkit_user_content_manager_register_script_message_handler_in_world(data->manager,"busyapiDocumentationPolicy","busyapi-policy");
  WebKitUserScript* policy=webkit_user_script_new_for_world(
      "(()=>{const report=kind=>window.webkit.messageHandlers.busyapiDocumentationPolicy.postMessage(kind);"
      "document.addEventListener('securitypolicyviolation',()=>report('resource'),true);"
      // Stop authored/vendor anchor navigation before WebKit can speculate a
      // DNS/preconnect. The native decide-policy handler remains a second gate.
      "document.addEventListener('click',event=>{const anchor=event.composedPath().find(node=>node instanceof HTMLAnchorElement);if(!anchor)return;"
      "let internal=false;try{const target=new URL(anchor.href,location.href),current=new URL(location.href);target.hash='';current.hash='';internal=target.href===current.href&&!anchor.hasAttribute('download');}catch{}"
      "if(!internal){event.preventDefault();event.stopImmediatePropagation();report('navigation');}},true);})();",
      WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,"busyapi-policy",nullptr,nullptr);
  webkit_user_content_manager_add_script(data->manager,policy);webkit_user_script_unref(policy);
  data->view=WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,"web-context",data->context,"user-content-manager",data->manager,nullptr));
  g_autoptr(WebKitSettings) settings=webkit_settings_new();
  // CE 3.0.1's view-state atoms require the standard storage API. It belongs
  // only to this window's ephemeral WebsiteDataManager, not the user profile
  // or another reference window. Do not copy a rasterizer's disabled-storage
  // setting into this interactive view or fake a browser storage shim.
  g_object_set(settings,"enable-html5-local-storage",TRUE,"enable-html5-database",FALSE,
      "javascript-can-open-windows-automatically",FALSE,"javascript-can-access-clipboard",FALSE,
      "enable-developer-extras",FALSE,"enable-page-cache",FALSE,"enable-site-specific-quirks",FALSE,
      "enable-dns-prefetching",FALSE,
      "enable-media-stream",FALSE,"enable-mediasource",FALSE,"enable-media",FALSE,"enable-webrtc",FALSE,
      "allow-file-access-from-file-urls",FALSE,"allow-universal-access-from-file-urls",FALSE,
      "enable-back-forward-navigation-gestures",FALSE,nullptr);
  webkit_web_view_set_settings(data->view,settings);
  g_signal_connect(data->view,"decide-policy",G_CALLBACK(policy_cb),self);
  g_signal_connect(data->view,"permission-request",G_CALLBACK(permission_cb),self);
  g_signal_connect(data->view,"create",G_CALLBACK(create_cb),self);
  g_signal_connect(data->view,"context-menu",G_CALLBACK(context_menu_cb),self);
  g_signal_connect(data->view,"load-failed",G_CALLBACK(load_failed_cb),self);
  g_signal_connect(data->view,"web-process-terminated",G_CALLBACK(terminated_cb),self);
  data->window=application?gtk_application_window_new(application):gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(data->window),title);gtk_window_set_default_size(GTK_WINDOW(data->window),1100,760);
  if(parent){gtk_window_set_transient_for(GTK_WINDOW(data->window),parent);gtk_window_set_destroy_with_parent(GTK_WINDOW(data->window),TRUE);}
  // Keep the interactive viewport mapped before initialization, independent
  // of its readiness message. This is not an offscreen/rasterizer view.
  data->stack=gtk_overlay_new();
  data->status=gtk_label_new(loading_label);gtk_label_set_line_wrap(GTK_LABEL(data->status),TRUE);
  gtk_widget_set_halign(data->status,GTK_ALIGN_CENTER);gtk_widget_set_valign(data->status,GTK_ALIGN_CENTER);
  gtk_widget_set_no_show_all(data->status,TRUE);gtk_widget_show(data->status);
  gtk_widget_set_sensitive(GTK_WIDGET(data->view),FALSE);
  gtk_container_add(GTK_CONTAINER(data->stack),GTK_WIDGET(data->view));
  gtk_overlay_add_overlay(GTK_OVERLAY(data->stack),data->status);
  auto* contents=gtk_box_new(GTK_ORIENTATION_VERTICAL,0);
  data->outdated=gtk_info_bar_new();gtk_info_bar_set_message_type(GTK_INFO_BAR(data->outdated),GTK_MESSAGE_WARNING);
  gtk_widget_set_name(data->outdated,"busyapi-documentation-outdated");
  data->outdated_label=gtk_label_new(nullptr);gtk_label_set_line_wrap(GTK_LABEL(data->outdated_label),TRUE);
  gtk_label_set_xalign(GTK_LABEL(data->outdated_label),0);
  gtk_container_add(GTK_CONTAINER(gtk_info_bar_get_content_area(GTK_INFO_BAR(data->outdated))),data->outdated_label);
  gtk_widget_show_all(data->outdated);gtk_widget_hide(data->outdated);gtk_widget_set_no_show_all(data->outdated,TRUE);
  gtk_box_pack_start(GTK_BOX(contents),data->outdated,FALSE,FALSE,0);
  gtk_box_pack_start(GTK_BOX(contents),data->stack,TRUE,TRUE,0);
  gtk_container_add(GTK_CONTAINER(data->window),contents);
  g_signal_connect(data->window,"destroy",G_CALLBACK(destroyed_cb),self);
  // Compile a closed filter before loading any page. This cache contains only
  // our public allowlist, never contract data, approved paths or credentials.
  g_autofree gchar* cache=g_build_filename(g_get_user_cache_dir(),"busyapi","documentation-filters",nullptr);
  if(g_mkdir_with_parents(cache,0700)!=0){
    g_set_error_literal(error,G_IO_ERROR,G_IO_ERROR_FAILED,"busyapi.documentation.isolation-unavailable");
    g_object_unref(self);return nullptr;
  }
  g_autoptr(WebKitUserContentFilterStore) store=webkit_user_content_filter_store_new(cache);
  std::vector<std::string> names;
  g_hash_table_iter_init(&iterator,resources);while(g_hash_table_iter_next(&iterator,&key,&value))names.emplace_back(static_cast<const char*>(key));
  std::sort(names.begin(),names.end());
  // WebKit's content-filter regexp subset deliberately excludes disjunctions.
  // Emit one exact allow rule per bounded resource instead of broadening it.
  std::string rules="[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}";
  for(const auto& name:names){
    std::string expression="^busyapi-doc://app/";
    for(const char at:name){if(at=='.')expression+="\\\\";expression+=at;}
    expression+='$';
    rules+=",{\"trigger\":{\"url-filter\":\""+expression+"\"},\"action\":{\"type\":\"ignore-previous-rules\"}}";
  }
  rules+=",{\"trigger\":{\"url-filter\":\"^data:\",\"resource-type\":[\"font\",\"image\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}]";
  g_autofree gchar* digest=g_compute_checksum_for_string(G_CHECKSUM_SHA256,rules.c_str(),rules.size());
  g_autoptr(GBytes) source=g_bytes_new(rules.data(),rules.size());
  webkit_user_content_filter_store_save(store,digest,source,data->cancellation,filter_ready_cb,g_object_ref(self));
  return self;
}

static void busyapi_documentation_window_dispose(GObject* object) {
  auto* self=BUSYAPI_DOCUMENTATION_WINDOW(object);busyapi_documentation_window_close(self);auto* data=self->data;
  g_clear_object(&data->context);g_clear_object(&data->manager);g_clear_object(&data->cancellation);
  G_OBJECT_CLASS(busyapi_documentation_window_parent_class)->dispose(object);
}
static void busyapi_documentation_window_finalize(GObject* object) {
  auto* data=BUSYAPI_DOCUMENTATION_WINDOW(object)->data;
  g_clear_pointer(&data->resources,g_hash_table_unref);g_free(data->snapshot);g_free(data->failure_label);delete data;
  G_OBJECT_CLASS(busyapi_documentation_window_parent_class)->finalize(object);
}
static void busyapi_documentation_window_class_init(BusyApiDocumentationWindowClass* klass) {
  auto* object=G_OBJECT_CLASS(klass);object->dispose=busyapi_documentation_window_dispose;object->finalize=busyapi_documentation_window_finalize;
  signals[kReady]=g_signal_new("ready",G_TYPE_FROM_CLASS(klass),G_SIGNAL_RUN_LAST,0,nullptr,nullptr,nullptr,G_TYPE_NONE,0);
  signals[kFailed]=g_signal_new("failed",G_TYPE_FROM_CLASS(klass),G_SIGNAL_RUN_LAST,0,nullptr,nullptr,nullptr,G_TYPE_NONE,1,G_TYPE_STRING);
  signals[kSource]=g_signal_new("source-request",G_TYPE_FROM_CLASS(klass),G_SIGNAL_RUN_LAST,0,nullptr,nullptr,nullptr,G_TYPE_NONE,1,G_TYPE_UINT);
  signals[kClosed]=g_signal_new("closed",G_TYPE_FROM_CLASS(klass),G_SIGNAL_RUN_LAST,0,nullptr,nullptr,nullptr,G_TYPE_NONE,0);
  signals[kBlocked]=g_signal_new("blocked",G_TYPE_FROM_CLASS(klass),G_SIGNAL_RUN_LAST,0,nullptr,nullptr,nullptr,G_TYPE_NONE,1,G_TYPE_STRING);
}
static void busyapi_documentation_window_init(BusyApiDocumentationWindow* self) {
  self->data=new WindowData();self->data->cancellation=g_cancellable_new();
}
