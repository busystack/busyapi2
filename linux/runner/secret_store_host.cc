// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// BusyAPI schema, identifiers and labels are deliberately independent.
#include "secret_store_host.h"

#include "secret_key_policy.h"

#include <libsecret/secret.h>

#include <cstring>

namespace {

constexpr char kChannelName[] = "com.busyapi.app/secure_credentials";
constexpr gsize kMaximumSecretBytes = 64 * 1024;

struct SecretRequest {
  FlMethodCall* method_call;
  gchar* key;
  gchar* secret;
};

SecretSchema* busyapi_schema() {
  static SecretSchema* schema =
      secret_schema_new("io.busystack.busyapi.request.credentials",
                        SECRET_SCHEMA_NONE, "reference",
                        SECRET_SCHEMA_ATTRIBUTE_STRING, nullptr);
  return schema;
}

const gchar* map_string(FlValue* args, const gchar* name) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* value = fl_value_lookup_string(args, name);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : nullptr;
}

void clear_secret(gchar* value) {
  if (value == nullptr) return;
  volatile gchar* cursor = value;
  for (gsize index = 0; value[index] != '\0'; ++index) cursor[index] = '\0';
  g_free(value);
}

SecretRequest* request_new(FlMethodCall* call, const gchar* key,
                           const gchar* secret = nullptr) {
  auto* request = g_new0(SecretRequest, 1);
  request->method_call = FL_METHOD_CALL(g_object_ref(G_OBJECT(call)));
  request->key = g_strdup(key);
  request->secret = g_strdup(secret);
  return request;
}

void request_free(SecretRequest* request) {
  if (request == nullptr) return;
  g_clear_object(&request->method_call);
  g_clear_pointer(&request->key, g_free);
  clear_secret(request->secret);
  g_free(request);
}

void respond_error(SecretRequest* request, GError* error) {
  const gchar* message = error != nullptr && error->message != nullptr
                             ? error->message
                             : "Secret Service is unavailable.";
  fl_method_call_respond_error(request->method_call,
                               "secret-store-unavailable", message, nullptr,
                               nullptr);
}

void lookup_finished(GObject*, GAsyncResult* result, gpointer data) {
  auto* request = static_cast<SecretRequest*>(data);
  g_autoptr(GError) error = nullptr;
  gchar* secret = secret_password_lookup_finish(result, &error);
  if (error != nullptr) {
    respond_error(request, error);
  } else {
    g_autoptr(FlValue) value = secret == nullptr ? fl_value_new_null()
                                                 : fl_value_new_string(secret);
    fl_method_call_respond_success(request->method_call, value, nullptr);
  }
  secret_password_free(secret);
  request_free(request);
}

void store_finished(GObject*, GAsyncResult* result, gpointer data) {
  auto* request = static_cast<SecretRequest*>(data);
  g_autoptr(GError) error = nullptr;
  const gboolean stored = secret_password_store_finish(result, &error);
  if (error != nullptr || !stored) {
    respond_error(request, error);
  } else {
    g_autoptr(FlValue) value = fl_value_new_null();
    fl_method_call_respond_success(request->method_call, value, nullptr);
  }
  request_free(request);
}

void clear_finished(GObject*, GAsyncResult* result, gpointer data) {
  auto* request = static_cast<SecretRequest*>(data);
  g_autoptr(GError) error = nullptr;
  secret_password_clear_finish(result, &error);
  if (error != nullptr) {
    respond_error(request, error);
  } else {
    g_autoptr(FlValue) value = fl_value_new_null();
    fl_method_call_respond_success(request->method_call, value, nullptr);
  }
  request_free(request);
}

// Metadata-only lookup: neither unlock the collection nor load secret values.
void availability_finished(GObject* service, GAsyncResult* result, gpointer data) {
  auto* request = static_cast<SecretRequest*>(data);
  g_autoptr(GError) error = nullptr;
  GList* items = secret_service_search_finish(SECRET_SERVICE(service), result, &error);
  if (error != nullptr) { respond_error(request, error); }
  else {
    bool unlocked = false;
    for (GList* item = items; item != nullptr; item = item->next)
      if (!secret_item_get_locked(SECRET_ITEM(item->data))) unlocked = true;
    g_autoptr(FlValue) value = fl_value_new_string(items == nullptr ? "missing" : unlocked ? "persistent" : "locked");
    fl_method_call_respond_success(request->method_call, value, nullptr);
  }
  g_list_free_full(items, g_object_unref);
  request_free(request);
}

void availability_service(GObject*, GAsyncResult* result, gpointer data) {
  auto* request = static_cast<SecretRequest*>(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(SecretService) service = secret_service_get_finish(result, &error);
  if (error != nullptr || service == nullptr) {
    respond_error(request, error); request_free(request); return;
  }
  GHashTable* attributes = secret_attributes_build(busyapi_schema(), "reference", request->key, nullptr);
  secret_service_search(service, busyapi_schema(), attributes, SECRET_SEARCH_NONE,
                        nullptr, availability_finished, request);
  g_hash_table_unref(attributes);
}

void invalid(FlMethodCall* call, const gchar* message) {
  fl_method_call_respond_error(call, "invalid-arguments", message, nullptr,
                               nullptr);
}

void method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  const gchar* key = map_string(args, "key");
  if (!busyapi_secrets::is_allowed_key(key)) {
    invalid(call, "Unsupported BusyAPI credential key.");
    return;
  }
  if (std::strcmp(method, "availability") == 0) {
    secret_service_get(SECRET_SERVICE_NONE, nullptr, availability_service, request_new(call, key));
    return;
  }
  if (std::strcmp(method, "read") == 0) {
    auto* request = request_new(call, key);
    secret_password_lookup(busyapi_schema(), nullptr, lookup_finished, request,
                           "reference", key, nullptr);
    return;
  }
  if (std::strcmp(method, "write") == 0) {
    const gchar* secret = map_string(args, "value");
    if (secret == nullptr || secret[0] == '\0' ||
        std::strlen(secret) > kMaximumSecretBytes) {
      invalid(call, "Credential value is empty or too large.");
      return;
    }
    auto* request = request_new(call, key, secret);
    secret_password_store(busyapi_schema(), SECRET_COLLECTION_DEFAULT,
                          "BusyAPI environment credential", request->secret,
                          nullptr, store_finished, request, "reference", key,
                          nullptr);
    return;
  }
  if (std::strcmp(method, "delete") == 0) {
    auto* request = request_new(call, key);
    secret_password_clear(busyapi_schema(), nullptr, clear_finished, request,
                          "reference", key, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(call, nullptr);
}

}  // namespace

FlMethodChannel* busyapi_secret_store_channel_new(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), kChannelName,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call, nullptr,
                                             nullptr);
  return channel;
}
