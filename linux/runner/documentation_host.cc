// BusyMark-derived platform-channel lifecycle pattern, Copyright 2026 BusyStack.
// Apache-2.0. Only owner-supplied immutable resources and opaque source indexes.
#include "documentation_host.h"
#include "documentation_runtime.h"

#include <cstring>
#include <map>
#include <memory>
#include <string>

struct DocumentationSession;
struct BusyApiDocumentationHost {
  FlMethodChannel* channel=nullptr;
  GtkWindow* parent=nullptr;
  GtkWidget* view=nullptr;
  gulong parent_destroy=0,view_destroy=0;
  std::map<gint64,std::unique_ptr<DocumentationSession>> sessions;
  std::string token;
  bool closing=false;
  const BusyApiDocumentationRuntime* runtime=nullptr;
};
struct DocumentationSession {
  BusyApiDocumentationHost* owner;
  gint64 id;
  std::string snapshot;
  std::string token;
  BusyApiDocumentationWindow* window=nullptr;
  ~DocumentationSession(){if(window){g_signal_handlers_disconnect_by_data(window,this);owner->runtime->close(window);g_object_unref(window);}}
};

namespace {
constexpr gsize kResourceBytes=16*1024*1024,kEntryBytes=32*1024*1024,kTotalBytes=128*1024*1024;
FlValue* field(FlValue* map,const char* name,FlValueType type) {
  if(!map||fl_value_get_type(map)!=FL_VALUE_TYPE_MAP)return nullptr;
  auto* value=fl_value_lookup_string(map,name);
  return value&&fl_value_get_type(value)==type?value:nullptr;
}
bool shape(FlValue* value,std::initializer_list<const char*> names) {
  if(!value||fl_value_get_type(value)!=FL_VALUE_TYPE_MAP||fl_value_get_length(value)!=names.size())return false;
  for(const auto* name:names)if(!fl_value_lookup_string(value,name))return false;
  return true;
}
bool integer(FlValue* args,const char* name,gint64 minimum,gint64 maximum,gint64* output) {
  auto* value=field(args,name,FL_VALUE_TYPE_INT);
  if(!value)return false;
  const auto number=fl_value_get_int(value);
  if(number<minimum||number>maximum)return false;
  *output=number;return true;
}
const char* text(FlValue* args,const char* name,gsize maximum) {
  auto* value=field(args,name,FL_VALUE_TYPE_STRING);
  const char* result=value?fl_value_get_string(value):nullptr;
  return result&&result[0]&&std::strlen(result)<=maximum&&g_utf8_validate(result,-1,nullptr)?result:nullptr;
}
void error(FlMethodCall* call,const char* code) {
  // No authored source, native paths or vendor error strings cross this boundary.
  fl_method_call_respond_error(call,code,"Documentation window request did not complete",nullptr,nullptr);
}
FlValue* connection(const char* token) {
  auto* value=fl_value_new_map();
  fl_value_set_string_take(value,"version",fl_value_new_int(1));
  fl_value_set_string_take(value,"owner",fl_value_new_string(token));
  return value;
}
FlValue* identity(gint64 id,const char* snapshot,const char* token) {
  auto* value=connection(token);
  fl_value_set_string_take(value,"id",fl_value_new_int(id));
  fl_value_set_string_take(value,"snapshot",fl_value_new_string(snapshot));
  return value;
}
void event(DocumentationSession* session,const char* kind,const char* code=nullptr,gint64 index=-1) {
  if(session->owner->closing||!session->owner->channel)return;
  g_autoptr(FlValue) payload=identity(session->id,session->snapshot.c_str(),session->token.c_str());
  fl_value_set_string_take(payload,"kind",fl_value_new_string(kind));
  if(code)fl_value_set_string_take(payload,"code",fl_value_new_string(code));
  if(index>=0)fl_value_set_string_take(payload,"index",fl_value_new_int(index));
  fl_method_channel_invoke_method(session->owner->channel,"event",payload,nullptr,nullptr,nullptr);
}
void ready(BusyApiDocumentationWindow*,gpointer data){event(static_cast<DocumentationSession*>(data),"ready");}
void failed(BusyApiDocumentationWindow*,const char* code,gpointer data){event(static_cast<DocumentationSession*>(data),"failed",code);}
void source(BusyApiDocumentationWindow*,guint index,gpointer data){event(static_cast<DocumentationSession*>(data),"source",nullptr,index);}
void blocked(BusyApiDocumentationWindow*,const char* capability,gpointer data){event(static_cast<DocumentationSession*>(data),"blocked",capability);}
void closed(BusyApiDocumentationWindow*,gpointer data) {
  auto* session=static_cast<DocumentationSession*>(data);auto* owner=session->owner;
  const auto id=session->id;
  event(session,"closed");
  // Disconnect before releasing the entry; the window keeps itself alive for
  // signal emission. No callback can retain a dangling session pointer.
  g_signal_handlers_disconnect_by_data(session->window,session);
  owner->sessions.erase(id);
}
void method(FlMethodChannel*,FlMethodCall* call,gpointer data) {
  auto* host=static_cast<BusyApiDocumentationHost*>(data);
  if(host->closing||!host->parent){error(call,"documentation.host.closed");return;}
  auto* args=fl_method_call_get_args(call);const char* name=fl_method_call_get_name(call);
  gint64 version=0,id=0;
  const char* owner=text(args,"owner",32);
  if(!integer(args,"version",1,1,&version)||!owner||std::strlen(owner)!=32||
      !g_regex_match_simple("^[a-f0-9]{32}$",owner,G_REGEX_OPTIMIZE,G_REGEX_MATCH_DEFAULT)) {
    error(call,"documentation.host.protocol");return;
  }
  if(std::strcmp(name,"attach")==0) {
    if(!shape(args,{"version","owner"})){error(call,"documentation.host.protocol");return;}
    // A restarted/replaced Dart owner cannot inherit old native window IDs or
    // navigation authority. No WebKit context is created by attachment itself.
    if(host->token!=owner){host->sessions.clear();host->token=owner;}
    g_autoptr(FlValue) result=connection(owner);fl_method_call_respond_success(call,result,nullptr);return;
  }
  if(host->token!=owner){error(call,"documentation.host.owner");return;}
  if(std::strcmp(name,"detach")==0) {
    if(!shape(args,{"version","owner"})){error(call,"documentation.host.protocol");return;}
    host->sessions.clear();host->token.clear();fl_method_call_respond_success(call,nullptr,nullptr);return;
  }
  const char* snapshot=text(args,"snapshot",256);
  if(!integer(args,"id",1,G_MAXINT32,&id)||!snapshot) {
    error(call,"documentation.host.protocol");return;
  }
  if(std::strcmp(name,"open")==0) {
    if(!shape(args,{"version","owner","id","snapshot","title","loading","failure","resources","sourceCount"})) {
      error(call,"documentation.host.protocol");return;
    }
    if(host->sessions.size()>=3||host->sessions.count(id)){error(call,"documentation.host.capacity");return;}
    const char* title=text(args,"title",4096),*loading=text(args,"loading",4096),*failure=text(args,"failure",4096);
    gint64 count=0;auto* supplied=field(args,"resources",FL_VALUE_TYPE_MAP);
    if(!title||!loading||!failure||!integer(args,"sourceCount",0,200000,&count)||!supplied||
        fl_value_get_length(supplied)==0||fl_value_get_length(supplied)>64){error(call,"documentation.host.protocol");return;}
    g_autoptr(GHashTable) resources=g_hash_table_new_full(g_str_hash,g_str_equal,g_free,reinterpret_cast<GDestroyNotify>(g_bytes_unref));
    gsize total=0;
    for(gsize at=0;at<fl_value_get_length(supplied);at++) {
      auto* key=fl_value_get_map_key(supplied,at);auto* bytes=fl_value_get_map_value(supplied,at);
      if(fl_value_get_type(key)!=FL_VALUE_TYPE_STRING||fl_value_get_type(bytes)!=FL_VALUE_TYPE_UINT8_LIST||
          fl_value_get_length(bytes)>(std::strcmp(fl_value_get_string(key),"index.html")==0?kEntryBytes:kResourceBytes)||
          (total+=fl_value_get_length(bytes))>kTotalBytes) {
        error(call,"documentation.host.resources");return;
      }
      // The window's closed resource loader validates the exact flat names,
      // snapshot syntax and entry resource; it is the single loading authority.
      g_hash_table_insert(resources,g_strdup(fl_value_get_string(key)),g_bytes_new(fl_value_get_uint8_list(bytes),fl_value_get_length(bytes)));
    }
    g_autoptr(GError) failure_detail=nullptr;
    if(!host->runtime)host->runtime=busyapi_documentation_runtime_load(&failure_detail);
    if(!host->runtime){
      error(call,failure_detail&&failure_detail->code==BUSYAPI_DOCUMENTATION_RUNTIME_LOAD?"documentation.host.runtime":"documentation.host.module");return;
    }
    auto* window=host->runtime->create(gtk_window_get_application(host->parent),host->parent,title,snapshot,resources,count,loading,failure,&failure_detail);
    if(!window){error(call,"documentation.host.resources");return;}
    auto session=std::make_unique<DocumentationSession>();session->owner=host;session->id=id;session->snapshot=snapshot;session->token=owner;session->window=window;
    auto* captured=session.get();host->sessions.emplace(id,std::move(session));
    g_signal_connect(window,"ready",G_CALLBACK(ready),captured);g_signal_connect(window,"failed",G_CALLBACK(failed),captured);
    g_signal_connect(window,"source-request",G_CALLBACK(source),captured);g_signal_connect(window,"blocked",G_CALLBACK(blocked),captured);
    g_signal_connect(window,"closed",G_CALLBACK(closed),captured);
    g_autoptr(FlValue) result=identity(id,snapshot,owner);fl_method_call_respond_success(call,result,nullptr);
    host->runtime->show(window);return;
  }
  const auto found=host->sessions.find(id);
  if(std::strcmp(name,"close")==0) {
    if(!shape(args,{"version","owner","id","snapshot"})||(found!=host->sessions.end()&&found->second->snapshot!=snapshot)) {
      error(call,"documentation.host.protocol");return;
    }
    if(found!=host->sessions.end())host->runtime->close(found->second->window);
    fl_method_call_respond_success(call,nullptr,nullptr);return;
  }
  if(std::strcmp(name,"outdated")==0) {
    const char* label=text(args,"label",4096);
    if(!shape(args,{"version","owner","id","snapshot","label"})||!label||found==host->sessions.end()||found->second->snapshot!=snapshot||
        !host->runtime->outdated(found->second->window,label)){error(call,"documentation.host.protocol");return;}
    fl_method_call_respond_success(call,nullptr,nullptr);return;
  }
  fl_method_call_respond_not_implemented(call,nullptr);
}
void shutdown(BusyApiDocumentationHost* host) {
  if(host->closing)return;
  host->closing=true;
  if(host->channel)fl_method_channel_set_method_call_handler(host->channel,nullptr,nullptr,nullptr);
  host->sessions.clear();g_clear_object(&host->channel);
  if(host->parent){g_signal_handler_disconnect(host->parent,host->parent_destroy);host->parent=nullptr;}
  if(host->view){g_signal_handler_disconnect(host->view,host->view_destroy);host->view=nullptr;}
}
void destroyed(GtkWidget*,gpointer data){shutdown(static_cast<BusyApiDocumentationHost*>(data));}
}  // namespace

BusyApiDocumentationHost* busyapi_documentation_host_new(FlView* view,GtkWindow* parent) {
  auto* host=new BusyApiDocumentationHost();host->parent=parent;host->view=GTK_WIDGET(view);
  host->parent_destroy=g_signal_connect(parent,"destroy",G_CALLBACK(destroyed),host);
  host->view_destroy=g_signal_connect(view,"destroy",G_CALLBACK(destroyed),host);
  g_autoptr(FlStandardMethodCodec) codec=fl_standard_method_codec_new();
  host->channel=fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)),"io.busystack.busyapi/documentation",FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(host->channel,method,host,nullptr);return host;
}
void busyapi_documentation_host_free(BusyApiDocumentationHost* host) {
  if(!host)return;
  shutdown(host);delete host;
}
