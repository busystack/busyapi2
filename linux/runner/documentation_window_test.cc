// Native GTK3/WebKit qualification of the same window used by the application.
// Test fixture assets are owned memory, not a project parser or vendor build.
#include "documentation_window.h"
#include <webkit2/webkit2.h>
#include <cstring>
#include <functional>
#include <map>
#include <string>
#include <vector>

#ifdef BUSYAPI_DOCUMENTATION_TEST_MODULE
#include "documentation_runtime.h"
namespace {
const BusyApiDocumentationRuntime* runtime() {
  g_autoptr(GError) error = nullptr;
  const auto* api = busyapi_documentation_runtime_load(&error);
  g_assert_no_error(error);
  g_assert_nonnull(api);
  return api;
}
}
#define busyapi_documentation_window_new runtime()->create
#define busyapi_documentation_window_show runtime()->show
#define busyapi_documentation_window_close runtime()->close
#define busyapi_documentation_window_set_outdated runtime()->outdated
#define busyapi_documentation_window_get_window runtime()->window
#define busyapi_documentation_window_get_view runtime()->view
#endif

namespace {
GtkApplication* application;
std::vector<std::string> optional_probe_denials;
bool optional_probes_expected=false;
void expect_confined_optional_probes() {
  // Test-only: WebKit 2.50.4 WTF/glib/ChassisType.cpp explicitly selects the
  // Desktop fallback after these optional probes fail. Preserve all default
  // fatal-warning handling; only exact, independently observed access-denial
  // messages may be expected once, in their upstream order.
  if(!g_getenv("BUSYAPI_DOCUMENTATION_TEST_EXPECT_HARDWARE_DENIALS"))return;
  g_assert_nonnull(g_getenv("SNAP"));
  for(const char* path:{"/sys/class/dmi/id/chassis_type","/sys/firmware/acpi/pm_profile"}) {
    g_autofree gchar* contents=nullptr;g_autoptr(GError) error=nullptr;
    if(!g_file_get_contents(path,&contents,nullptr,&error)&&g_error_matches(error,G_FILE_ERROR,G_FILE_ERROR_ACCES)) {
      g_autofree gchar* message=g_strdup_printf("Could not open %s: %s",path,error->message);
      optional_probe_denials.emplace_back(message);
    }
  }
}
void unexpected_warning_is_fatal() {
  if(g_test_subprocess()) {g_warning("Controlled unexpected native warning");return;}
  g_test_trap_subprocess(nullptr,5*G_TIME_SPAN_SECOND,G_TEST_SUBPROCESS_DEFAULT);
  g_test_trap_assert_failed();g_test_trap_assert_stderr("*Controlled unexpected native warning*");
}
struct Observation {
  guint ready=0,closed=0,source=0,blocked=0;
  guint source_index=1;
  std::string failure;
  std::map<std::string,guint> blocked_types;
};
void connect(BusyApiDocumentationWindow* window,Observation* observed) {
  g_signal_connect(window,"ready",G_CALLBACK(+[](BusyApiDocumentationWindow*,gpointer value){static_cast<Observation*>(value)->ready++;}),observed);
  g_signal_connect(window,"closed",G_CALLBACK(+[](BusyApiDocumentationWindow*,gpointer value){static_cast<Observation*>(value)->closed++;}),observed);
  g_signal_connect(window,"source-request",G_CALLBACK(+[](BusyApiDocumentationWindow*,guint index,gpointer value){auto* observed=static_cast<Observation*>(value);g_assert_cmpuint(index,==,observed->source_index);observed->source++;}),observed);
  g_signal_connect(window,"blocked",G_CALLBACK(+[](BusyApiDocumentationWindow*,const gchar* capability,gpointer value){auto* observed=static_cast<Observation*>(value);observed->blocked++;observed->blocked_types[capability]++;}),observed);
  g_signal_connect(window,"failed",G_CALLBACK(+[](BusyApiDocumentationWindow*,const gchar* code,gpointer value){static_cast<Observation*>(value)->failure=code;}),observed);
}
void pump_until(const std::function<bool()>& done,const std::function<void()>& timed_out={}) {
  // Observe the host's own 30-second failure deadline as well as readiness.
  const gint64 deadline=g_get_monotonic_time()+35*G_TIME_SPAN_SECOND;
  while(!done()&&g_get_monotonic_time()<deadline){while(g_main_context_iteration(nullptr,FALSE)){};g_usleep(1000);}
  if(!done()&&timed_out)timed_out();
  g_assert_true(done());
}
void add(GHashTable* resources,const char* name,const char* text) {
  g_hash_table_insert(resources,g_strdup(name),g_bytes_new(text,std::strlen(text)));
}
GHashTable* fixture() {
  auto* resources=g_hash_table_new_full(g_str_hash,g_str_equal,g_free,reinterpret_cast<GDestroyNotify>(g_bytes_unref));
  add(resources,"index.html","<!doctype html><html><head><meta charset=utf-8><script src=classic.js></script><script type=module src=bootstrap.mjs></script></head><body><h1 id=content>Loading</h1><a id=external href=https://must-not-load.invalid>External</a><a id=download download=source.txt href=snapshot.json>Download</a></body></html>");
  add(resources,"classic.js","window.classicFixture='classic local script';");
  add(resources,"snapshot.json","{\"text\":\"Exact 雪😀 9007199254740993.00\"}");
  add(resources,"bootstrap.mjs","if(window.classicFixture!=='classic local script')throw Error('Missing classic script');const value=await(await fetch('snapshot.json')).json();document.getElementById('content').textContent=value.text;window.post=object=>window.webkit.messageHandlers.busyapiDocumentation.postMessage(object);window.post({version:1,snapshot:'snapshot-1',kind:'ready'});");
  return resources;
}
BusyApiDocumentationWindow* create(GHashTable* resources,Observation* observed,const char* snapshot="snapshot-1",guint source_count=2) {
  if(!optional_probes_expected&&!optional_probe_denials.empty()) {
    for(const auto& message:optional_probe_denials)g_test_expect_message(nullptr,G_LOG_LEVEL_WARNING,message.c_str());
    optional_probes_expected=true;
  }
  g_autoptr(GError) error=nullptr;
  auto* window=busyapi_documentation_window_new(application,nullptr,"BusyAPI documentation fixture",snapshot,resources,source_count,"Loading","Documentation failed",&error);
  g_assert_no_error(error);g_assert_nonnull(window);connect(window,observed);
  if(g_getenv("BUSYAPI_DOCUMENTATION_TEST_TRACE")) {
    auto* view=busyapi_documentation_window_get_view(window);
    g_object_set(webkit_web_view_get_settings(view),"enable-write-console-messages-to-stdout",TRUE,nullptr);
    g_signal_connect(view,"load-changed",G_CALLBACK(+[](WebKitWebView*,WebKitLoadEvent event,gpointer){g_test_message("Native fixture load event: %u",event);}),nullptr);
    g_signal_connect(view,"resource-load-started",G_CALLBACK(+[](WebKitWebView*,WebKitWebResource* resource,WebKitURIRequest* request,gpointer){
      g_test_message("Native fixture resource: %s",webkit_uri_request_get_uri(request));
      g_signal_connect(resource,"failed",G_CALLBACK(+[](WebKitWebResource*,GError* error,gpointer){g_test_message("Native fixture resource failure: %s %d %.1000s",g_quark_to_string(error->domain),error->code,error->message);}),nullptr);
      g_signal_connect(resource,"notify::response",G_CALLBACK(+[](GObject* object,GParamSpec*,gpointer){
        auto* response=webkit_web_resource_get_response(WEBKIT_WEB_RESOURCE(object));
        if(response)g_test_message("Native fixture response: %u %s",webkit_uri_response_get_status_code(response),webkit_uri_response_get_mime_type(response));
      }),nullptr);
    }),nullptr);
  }
  // Generated fixtures only. Preserve failure details in ordinary runs too;
  // this handler is absent from the application and is not a content oracle.
  auto* manager=webkit_web_view_get_user_content_manager(busyapi_documentation_window_get_view(window));
  g_signal_connect(manager,"script-message-received::busyapiFixture",G_CALLBACK(+[](WebKitUserContentManager*,WebKitJavascriptResult* result,gpointer){
    JSCValue* value=webkit_javascript_result_get_js_value(result);
    if(jsc_value_is_string(value)){g_autofree gchar* text=jsc_value_to_string(value);g_test_message("Native fixture diagnostic: %.2000s",text);}
  }),nullptr);
  webkit_user_content_manager_register_script_message_handler(manager,"busyapiFixture");
  gtk_window_set_focus_on_map(busyapi_documentation_window_get_window(window),FALSE);
  busyapi_documentation_window_show(window);return window;
}
std::string evaluate(BusyApiDocumentationWindow* window,const char* script) {
  struct Evaluation{bool done=false;std::string value;GError* error=nullptr;} result;
  webkit_web_view_evaluate_javascript(busyapi_documentation_window_get_view(window),script,-1,nullptr,nullptr,nullptr,
      +[](GObject* object,GAsyncResult* completion,gpointer user_data){
        auto* result=static_cast<Evaluation*>(user_data);
        g_autoptr(JSCValue) value=webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(object),completion,&result->error);
        if(value){g_autofree gchar* text=jsc_value_to_string(value);result->value=text;}
        result->done=true;
      },&result);
  pump_until([&]{return result.done;});g_assert_no_error(result.error);return result.value;
}
void ordinary() {
  Observation observed;g_autoptr(GHashTable) resources=fixture();
  g_autoptr(BusyApiDocumentationWindow) window=create(resources,&observed);
  pump_until([&]{return observed.ready||!observed.failure.empty();});g_assert_cmpstr(observed.failure.c_str(),==,"");g_assert_cmpuint(observed.ready,==,1);g_assert_cmpuint(observed.blocked,==,0);
  const auto actual=evaluate(window,"document.getElementById('content').textContent");
  g_assert_cmpstr(actual.c_str(),==,"Exact 雪😀 9007199254740993.00");
  auto* context=webkit_web_view_get_context(busyapi_documentation_window_get_view(window));
  g_assert_true(webkit_web_context_is_ephemeral(context));g_assert_true(webkit_web_context_get_sandbox_enabled(context));
  evaluate(window,"post({version:1,snapshot:'snapshot-1',kind:'source',index:1});post({version:1,snapshot:'stale',kind:'source',index:1});post({version:1,snapshot:'snapshot-1',kind:'source',index:2});post({version:1,snapshot:'snapshot-1',kind:'source',index:0.5});post({version:1,snapshot:'snapshot-1',kind:'source',index:1,command:'shell'});'done'");
  pump_until([&]{return observed.source==1&&observed.blocked==4;});
  busyapi_documentation_window_close(window);g_assert_cmpuint(observed.closed,==,1);g_assert_null(busyapi_documentation_window_get_view(window));
  busyapi_documentation_window_close(window);g_assert_cmpuint(observed.closed,==,1);
}
void adversarial() {
  Observation observed;g_autoptr(GHashTable) resources=fixture();g_autoptr(BusyApiDocumentationWindow) window=create(resources,&observed);
  pump_until([&]{return observed.ready||!observed.failure.empty();});g_assert_cmpstr(observed.failure.c_str(),==,"");
  // Negative attempts are deliberately distinct from the ordinary case. The
  // fixture records CSP violations without shipping a console/log listener.
  evaluate(window,"window.violations=[];document.addEventListener('securitypolicyviolation',e=>violations.push(e.violatedDirective));window.outcomes=[];for(const url of ['https://must-not-load.invalid/data','http://127.0.0.1:9/data','file:///etc/passwd','busyapi-doc://other/snapshot.json','busyapi-doc://app/missing.json'])fetch(url).then(()=>outcomes.push('escaped'),()=>outcomes.push('denied'));try{new WebSocket('wss://must-not-load.invalid/socket')}catch{};const image=new Image();image.src='https://must-not-load.invalid/image';document.body.append(image);const script=document.createElement('script');script.src='https://must-not-load.invalid/script';document.body.append(script);const frame=document.createElement('iframe');frame.src='busyapi-doc://app/snapshot.json';document.body.append(frame);document.getElementById('external').click();'done'");
  pump_until([&]{return evaluate(window,"outcomes.length")=="5";});
  const auto outcomes=evaluate(window,"JSON.stringify(outcomes)");
  g_assert_cmpstr(outcomes.c_str(),==,"[\"denied\",\"denied\",\"denied\",\"denied\",\"denied\"]");
  g_assert_true(evaluate(window,"violations.includes('connect-src')&&violations.includes('script-src-elem')&&violations.includes('frame-src')")=="true");
  g_assert_cmpuint(observed.blocked,>=,5);
  g_assert_true(evaluate(window,"location.href")=="busyapi-doc://app/index.html");g_assert_cmpuint(observed.ready,==,1);g_assert_cmpstr(observed.failure.c_str(),==,"");
  pump_until([&]{return observed.blocked_types["navigation"]>=1;});
  const auto navigations=observed.blocked_types["navigation"];
  g_assert_true(evaluate(window,"window.open('https://must-not-load.invalid/popup','_blank')===null")=="true");
  evaluate(window,"document.getElementById('download').click();'done'");
  pump_until([&]{return observed.blocked_types["download"]>0||observed.blocked_types["navigation"]>navigations;});
  busyapi_documentation_window_close(window);
}
void outdated_snapshot() {
  for(const bool before_ready:{true,false}) {
    Observation observed;g_autoptr(GHashTable) resources=fixture();
    g_autoptr(BusyApiDocumentationWindow) window=create(resources,&observed);
    const char* label="Outdated snapshot · 雪😀 — reopen before source navigation";
    g_assert_false(busyapi_documentation_window_set_outdated(window,""));
    if(before_ready)g_assert_true(busyapi_documentation_window_set_outdated(window,label));
    pump_until([&]{return observed.ready||!observed.failure.empty();});g_assert_cmpstr(observed.failure.c_str(),==,"");
    if(!before_ready) {
      evaluate(window,"window.readingSentinel='unchanged';post({version:1,snapshot:'snapshot-1',kind:'source',index:1});'done'");
      pump_until([&]{return observed.source==1;});
      g_assert_true(busyapi_documentation_window_set_outdated(window,label));
      g_assert_true(evaluate(window,"readingSentinel")=="unchanged");
    }
    auto* contents=gtk_bin_get_child(GTK_BIN(busyapi_documentation_window_get_window(window)));
    GList* children=gtk_container_get_children(GTK_CONTAINER(contents));
    auto* banner=GTK_WIDGET(children->data);g_assert_true(GTK_IS_INFO_BAR(banner));g_assert_true(gtk_widget_get_visible(banner));g_list_free(children);
    children=gtk_container_get_children(GTK_CONTAINER(gtk_info_bar_get_content_area(GTK_INFO_BAR(banner))));
    g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(children->data)),==,label);g_list_free(children);
    const auto count=observed.source;
    evaluate(window,"post({version:1,snapshot:'snapshot-1',kind:'source',index:1});'done'");
    pump_until([&]{return observed.blocked==1;});g_assert_cmpuint(observed.source,==,count);
    g_assert_true(evaluate(window,"document.getElementById('content').textContent")=="Exact 雪😀 9007199254740993.00");
    busyapi_documentation_window_close(window);g_assert_false(busyapi_documentation_window_set_outdated(window,label));
    g_assert_cmpuint(observed.closed,==,1);
  }
}
void crash_reopen() {
  g_autoptr(GHashTable) resources=fixture();
  for(int attempt=0;attempt<2;attempt++){
    Observation observed;g_autoptr(BusyApiDocumentationWindow) window=create(resources,&observed);
    pump_until([&]{return observed.ready||!observed.failure.empty();});g_assert_cmpstr(observed.failure.c_str(),==,"");
    webkit_web_view_terminate_web_process(busyapi_documentation_window_get_view(window));
    pump_until([&]{return !observed.failure.empty();});g_assert_cmpstr(observed.failure.c_str(),==,"busyapi.documentation.process-terminated");
    busyapi_documentation_window_close(window);g_assert_cmpuint(observed.closed,==,1);
  }
}
void cancel_loading() {
  g_autoptr(GHashTable) resources=fixture();Observation observed;
  g_autoptr(BusyApiDocumentationWindow) window=create(resources,&observed);busyapi_documentation_window_close(window);
  pump_until([&]{return observed.closed==1;});
  const auto end=g_get_monotonic_time()+G_TIME_SPAN_SECOND;while(g_get_monotonic_time()<end){while(g_main_context_iteration(nullptr,FALSE)){};g_usleep(1000);}
  g_assert_cmpuint(observed.ready,==,0);g_assert_cmpstr(observed.failure.c_str(),==,"");
}
void ephemeral_storage() {
  g_autoptr(GHashTable) resources=fixture();Observation first_observed,second_observed,third_observed;
  g_autoptr(BusyApiDocumentationWindow) first=create(resources,&first_observed);
  pump_until([&]{return first_observed.ready||!first_observed.failure.empty();});g_assert_cmpstr(first_observed.failure.c_str(),==,"");
  g_assert_true(evaluate(first,"localStorage.setItem('busyapi-fixture-view','first');localStorage.getItem('busyapi-fixture-view')")=="first");
  g_autoptr(BusyApiDocumentationWindow) second=create(resources,&second_observed);
  pump_until([&]{return second_observed.ready||!second_observed.failure.empty();});g_assert_cmpstr(second_observed.failure.c_str(),==,"");
  g_assert_true(evaluate(second,"localStorage.getItem('busyapi-fixture-view')===null")=="true");
  g_assert_true(evaluate(first,"localStorage.getItem('busyapi-fixture-view')")=="first");
  auto* manager=webkit_web_context_get_website_data_manager(webkit_web_view_get_context(busyapi_documentation_window_get_view(first)));
  g_assert_true(webkit_website_data_manager_is_ephemeral(manager));
  busyapi_documentation_window_close(first);busyapi_documentation_window_close(second);
  g_autoptr(BusyApiDocumentationWindow) third=create(resources,&third_observed);
  pump_until([&]{return third_observed.ready||!third_observed.failure.empty();});g_assert_cmpstr(third_observed.failure.c_str(),==,"");
  g_assert_true(evaluate(third,"localStorage.getItem('busyapi-fixture-view')===null")=="true");
  busyapi_documentation_window_close(third);
}
void invalid_resources() {
  g_autoptr(GHashTable) resources=fixture();add(resources,"../private.js","not allowed");g_autoptr(GError) error=nullptr;
  auto* window=busyapi_documentation_window_new(nullptr,nullptr,"T","snapshot-1",resources,0,"Loading","Failed",&error);
  g_assert_null(window);g_assert_error(error,G_IO_ERROR,G_IO_ERROR_INVALID_ARGUMENT);
  // The larger located-document allowance is exclusive to the HTML entry.
  for(const auto* name:{"index.html","vendor.js"}) {
    g_autoptr(GHashTable) bounded=fixture();
    const gsize size=(std::strcmp(name,"index.html")==0?32:16)*1024*1024+1;
    g_hash_table_replace(bounded,g_strdup(name),g_bytes_new_take(g_malloc0(size),size));
    g_autoptr(GError) overflow=nullptr;
    auto* rejected=busyapi_documentation_window_new(nullptr,nullptr,"T","snapshot-1",bounded,0,"Loading","Failed",&overflow);
    g_assert_null(rejected);g_assert_error(overflow,G_IO_ERROR,G_IO_ERROR_INVALID_ARGUMENT);
  }
}
void renderer_fixture() {
  const char* directory=g_getenv("BUSYAPI_DOCUMENTATION_RENDERER_FIXTURES");g_assert_nonnull(directory);
  const char* current=g_test_get_path();const char* name=std::strrchr(current,'/');g_assert_nonnull(name);name++;
  g_autoptr(GHashTable) resources=g_hash_table_new_full(g_str_hash,g_str_equal,g_free,reinterpret_cast<GDestroyNotify>(g_bytes_unref));
  for(const char* asset:{"index.html","bootstrap.mjs","snapshot.json","vendor.js","vendor.css","graph_display.mjs","source_actions.mjs","adapter.mjs"}){
    g_autofree gchar* filename=g_build_filename(directory,name,asset,nullptr);gchar* content=nullptr;gsize size=0;g_autoptr(GError) error=nullptr;
    g_file_get_contents(filename,&content,&size,&error);g_assert_no_error(error);
    g_hash_table_insert(resources,g_strdup(asset),g_bytes_new_take(content,size));
  }
  Observation observed;g_autoptr(BusyApiDocumentationWindow) window=create(resources,&observed);
  pump_until([&]{return observed.ready||!observed.failure.empty();});
  g_assert_cmpstr(observed.failure.c_str(),==,"");g_assert_cmpuint(observed.ready,==,1);g_assert_cmpuint(observed.blocked,==,0);
  g_assert_true(evaluate(window,"fixtureSeen.join('\\n').includes('Schema property sentinel')")=="true");
  // Exact captured data remains in the page only; no source values are logged.
  g_assert_true(evaluate(window,"capturedSource.includes('payload data')")=="true");
  if(g_str_has_prefix(name,"redoc-")) {
    g_assert_true(evaluate(window,"fixtureBooleans.includes('false')")=="true");
    g_assert_true(evaluate(window,"fixtureAuthoredValues['/paths/~1native-exact/post/requestBody/content/application~1json/example'].includes('9007199254740993.0')")=="true");
    g_assert_true(evaluate(window,"fixtureAuthoredValues['/paths/~1native-exact/post/requestBody/content/text~1plain/example'].includes('serialized \\u96ea\\ud83d\\ude00')")=="true");
    g_assert_true(evaluate(window,"!fixtureSeen.join('\\n').includes('9007199254740992')")=="true");
    g_assert_true(evaluate(window,"fixtureSeen.join('\\n').includes('Inherited')")=="true");
  }
  evaluate(window,"fixtureShowSource()");
  pump_until([&]{return evaluate(window,"!!document.querySelector('[data-busyapi-source=\"1\"]')")=="true";});
  evaluate(window,"document.querySelector('[data-busyapi-source=\"1\"]').click()");
  pump_until([&]{return observed.source==1;});
  g_assert_true(busyapi_documentation_window_set_outdated(window,"Outdated captured fixture"));
  evaluate(window,"document.querySelector('[data-busyapi-source=\"1\"]').click()");
  pump_until([&]{return observed.blocked>0;});
  g_assert_cmpuint(observed.source,==,1);
  busyapi_documentation_window_close(window);g_assert_cmpuint(observed.closed,==,1);
}
void production_legacy_renderer_fixture() {
  const char* directory=g_getenv("BUSYAPI_DOCUMENTATION_PRODUCTION_FIXTURES");g_assert_nonnull(directory);
  const char* name=std::strrchr(g_test_get_path(),'/');g_assert_nonnull(name);name++;
  g_autofree gchar* metadata_file=g_build_filename(directory,name,"presentation.ini",nullptr);
  g_autoptr(GKeyFile) metadata=g_key_file_new();g_autoptr(GError) error=nullptr;
  g_assert_true(g_key_file_load_from_file(metadata,metadata_file,G_KEY_FILE_NONE,&error));g_assert_no_error(error);
  g_autofree gchar* snapshot=g_key_file_get_string(metadata,"presentation","snapshot",&error);g_assert_no_error(error);
  const guint count=g_key_file_get_integer(metadata,"presentation","source_count",&error);g_assert_no_error(error);
  Observation observed;observed.source_index=g_key_file_get_integer(metadata,"presentation","source_index",&error);g_assert_no_error(error);g_assert_cmpuint(observed.source_index,<,count);
  g_autoptr(GHashTable) resources=g_hash_table_new_full(g_str_hash,g_str_equal,g_free,reinterpret_cast<GDestroyNotify>(g_bytes_unref));
  const bool swagger=g_str_has_prefix(name,"swagger-");
  const std::vector<const char*> names=swagger?std::vector<const char*>{"index.html","swagger.js","swagger.css","bootstrap.js"}:std::vector<const char*>{"index.html","redoc.js","bootstrap.js"};
  for(const char* asset:names){
    g_autofree gchar* filename=g_build_filename(directory,name,asset,nullptr);gchar* contents=nullptr;gsize size=0;
    g_file_get_contents(filename,&contents,&size,&error);g_assert_no_error(error);
    g_hash_table_insert(resources,g_strdup(asset),g_bytes_new_take(contents,size));
  }
  g_autofree gchar* expected_file=g_build_filename(directory,name,"expected.json",nullptr);
  gchar* expected=nullptr;gsize expected_size=0;g_file_get_contents(expected_file,&expected,&expected_size,&error);g_assert_no_error(error);
  g_autofree gchar* encoded=g_base64_encode(reinterpret_cast<const guchar*>(expected),expected_size);g_free(expected);
  g_autoptr(BusyApiDocumentationWindow) window=create(resources,&observed,snapshot,count);
  pump_until([&]{return observed.ready||!observed.failure.empty();});g_assert_cmpstr(observed.failure.c_str(),==,"");g_assert_cmpuint(observed.ready,==,1);
  auto* context=webkit_web_view_get_context(busyapi_documentation_window_get_view(window));
  g_assert_true(webkit_web_context_is_ephemeral(context));g_assert_true(webkit_web_context_get_sandbox_enabled(context));
  g_autofree gchar* reader=g_strdup_printf(R"JS(
    window.legacyDone=false;window.legacyFailure='';window.legacySeen=[];window.legacyValues=Object.create(null);
    window.legacyExpected=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('%s'),v=>v.charCodeAt(0))));
    (async()=>{
      const routes=new Set(['#/']),visited=new Set(),sleep=()=>new Promise(resolve=>setTimeout(resolve,30));
      const capture=()=>{
        legacySeen.push(document.body.innerText);
        for(const node of document.querySelectorAll('[data-busyapi-authored-value]'))if(node.getClientRects().length&&getComputedStyle(node).visibility!=='hidden'){
          const key=node.getAttribute('data-busyapi-authored-value'),values=legacyValues[key]??=[];if(!values.includes(node.textContent))values.push(node.textContent);
        }
      };
      for(let routeCount=0;routeCount<40;routeCount++){
        const route=[...routes].find(value=>!visited.has(value));if(route===undefined)break;
        visited.add(route);location.hash=route.slice(1);await sleep();
        const definitions=new Set();
        for(let pass=0;pass<50;pass++){
          for(const branch of document.querySelectorAll('[data-busyapi-authored-branch]'))branch.open=true;
          await sleep();capture();
          for(const anchor of document.querySelectorAll('a[href]')){const target=new URL(anchor.href);if(target.hash.startsWith('#/'))routes.add(target.hash);}
          if(document.querySelector('[data-busyapi-source="%u"]'))window.legacySourceRoute=route;
          const button=[...document.querySelectorAll('[data-busyapi-definition]')].find(node=>node.getClientRects().length&&!definitions.has(node.getAttribute('data-busyapi-definition')));
          const back=button?null:[...document.querySelectorAll('button')].find(node=>node.getClientRects().length&&node.textContent.startsWith('← '));
          if(button||back){
            const control=button||back,panel=control.closest('[data-busyapi-authored-panel]');
            const target=button?button.getAttribute('data-busyapi-definition'):panel?.getAttribute('data-busyapi-authored-panel');
            if(button)definitions.add(target);control.click();
            const deadline=performance.now()+3000;
            while(panel?.isConnected&&panel.querySelector(':scope > [data-busyapi-authored-content]')?.getAttribute('data-busyapi-authored-content')!==target){
              if(performance.now()>deadline)throw Error('Legacy native definition did not mount');await sleep();
            }
          }
          for(const node of [document.scrollingElement,...document.querySelectorAll('.api-content,[data-scroll-container]')])if(node)node.scrollTop+=400;
        }
        for(const tab of document.querySelectorAll('[role=tab]'))if(tab.textContent==='Example Value')tab.click();
        await sleep();capture();
      }
      if(routes.size>=40||window.legacySourceRoute===undefined)throw Error('Incomplete native legacy route/source inventory');
    })().catch(error=>{legacyFailure=String(error.message);}).finally(()=>{legacyDone=true;});'started'
  )JS",encoded,observed.source_index);
  evaluate(window,reader);pump_until([&]{return evaluate(window,"legacyDone")=="true";});g_assert_true(evaluate(window,"legacyFailure===''")=="true");
  for(const char* text:{"Compatibility operation sentinel","Schema property sentinel","payload data","Unsaved native legacy capture sentinel"}){
    g_autofree gchar* check=g_strdup_printf("legacySeen.join('\\n').includes('%s')",text);
    if(evaluate(window,check)!="true")g_test_message("Missing legacy content: %s; %.3000s",text,evaluate(window,"legacySeen.join('\\n').slice(-3000)").c_str());
    g_assert_true(evaluate(window,check)=="true");
  }
  for(const char* check:{"legacyValues[legacyExpected.minimum]?.includes('9007199254740993')","legacyValues[legacyExpected.schemaExample]?.includes('9007199254740993.0')","legacyValues[legacyExpected.example]?.includes(legacyExpected.exampleValue)"}){
    if(evaluate(window,check)!="true")g_test_message("Missing exact legacy field: %s; %.5000s",check,evaluate(window,"JSON.stringify(legacyValues)").c_str());
    g_assert_true(evaluate(window,check)=="true");
  }
  g_assert_cmpuint(observed.blocked,==,0);
  evaluate(window,"location.hash=legacySourceRoute.slice(1);'source'");
  g_autofree gchar* exists=g_strdup_printf("!!document.querySelector('[data-busyapi-source=\"%u\"]')",observed.source_index);
  pump_until([&]{return evaluate(window,exists)=="true";});
  g_autofree gchar* click=g_strdup_printf("document.querySelector('[data-busyapi-source=\"%u\"]').click();'clicked'",observed.source_index);
  evaluate(window,click);pump_until([&]{return observed.source==1;});
  g_assert_true(busyapi_documentation_window_set_outdated(window,"Outdated legacy capture"));evaluate(window,click);pump_until([&]{return observed.blocked>0;});g_assert_cmpuint(observed.source,==,1);
  busyapi_documentation_window_close(window);g_assert_cmpuint(observed.closed,==,1);
}
void production_renderer_fixture() {
  const char* directory=g_getenv("BUSYAPI_DOCUMENTATION_PRODUCTION_FIXTURES");g_assert_nonnull(directory);
  const char* name=std::strrchr(g_test_get_path(),'/');g_assert_nonnull(name);name++;
  g_autofree gchar* metadata_file=g_build_filename(directory,name,"presentation.ini",nullptr);
  g_autoptr(GKeyFile) metadata=g_key_file_new();g_autoptr(GError) error=nullptr;
  g_assert_true(g_key_file_load_from_file(metadata,metadata_file,G_KEY_FILE_NONE,&error));g_assert_no_error(error);
  g_autofree gchar* snapshot=g_key_file_get_string(metadata,"presentation","snapshot",&error);g_assert_no_error(error);
  const guint count=g_key_file_get_integer(metadata,"presentation","source_count",&error);g_assert_no_error(error);
  const guint callback_index=g_key_file_get_integer(metadata,"presentation","callback_source_index",&error);g_assert_no_error(error);g_assert_cmpuint(callback_index,<,count);
  Observation observed;observed.source_index=g_key_file_get_integer(metadata,"presentation","source_index",&error);g_assert_no_error(error);g_assert_cmpuint(observed.source_index,<,count);
  g_autoptr(GHashTable) resources=g_hash_table_new_full(g_str_hash,g_str_equal,g_free,reinterpret_cast<GDestroyNotify>(g_bytes_unref));
  const bool swagger=g_str_has_prefix(name,"swagger-");
  g_autofree gchar* context_one=g_key_file_get_string(metadata,"presentation","context_route_one",&error);g_assert_no_error(error);
  g_autofree gchar* context_two=g_key_file_get_string(metadata,"presentation","context_route_two",&error);g_assert_no_error(error);
  for(const char* route:{context_one,context_two}){g_assert_true(g_str_has_prefix(route,"/busyapi-operation/"));g_assert_cmpuint(std::strlen(route),==,83);g_assert_cmpuint(std::strspn(route+19,"0123456789abcdef"),==,64);}
  const std::vector<const char*> asset_names=swagger?std::vector<const char*>{"index.html","swagger.js","swagger.css","bootstrap.js"}:std::vector<const char*>{"index.html","redoc.js","bootstrap.js"};
  for(const char* asset:asset_names){
    g_autofree gchar* filename=g_build_filename(directory,name,asset,nullptr);gchar* contents=nullptr;gsize size=0;
    g_file_get_contents(filename,&contents,&size,&error);g_assert_no_error(error);
    g_hash_table_insert(resources,g_strdup(asset),g_bytes_new_take(contents,size));
  }
  g_autoptr(BusyApiDocumentationWindow) window=create(resources,&observed,snapshot,count);
  pump_until([&]{return observed.ready||!observed.failure.empty();});g_assert_cmpstr(observed.failure.c_str(),==,"");g_assert_cmpuint(observed.ready,==,1);g_assert_cmpuint(observed.blocked,==,0);
  auto* context=webkit_web_view_get_context(busyapi_documentation_window_get_view(window));
  g_assert_true(webkit_web_context_is_ephemeral(context));g_assert_true(webkit_web_context_get_sandbox_enabled(context));
  g_autofree gchar* reader=g_strdup_printf(R"JS(
    window.productionDone=false;window.productionFailure='';window.productionSeen=[];window.productionValues=Object.create(null);window.productionRouteDetails=[];window.productionContextTexts=Object.create(null);window.productionContextNodes=Object.create(null);
    (async()=>{
      const routes=new Set(['#/']),visited=new Set(),readPages=new Set(),sleep=()=>new Promise(resolve=>setTimeout(resolve,25));
      const visible=node=>node.isConnected&&node.getClientRects().length&&getComputedStyle(node).visibility!=='hidden';
      window.productionRoutes=routes;window.productionVisited=visited;
      const expand=async()=>{
        const deadline=performance.now()+3000;
        while(true){
          for(const branch of document.querySelectorAll('[data-busyapi-authored-branch]'))branch.open=true;
          await sleep();
          if([...document.querySelectorAll('[data-busyapi-authored-branch]')].every(branch=>[...branch.querySelectorAll('[data-busyapi-authored-content]')].some(node=>node.getAttribute('data-busyapi-authored-content')===branch.getAttribute('data-busyapi-authored-branch'))))return;
          if(performance.now()>deadline)throw Error('Native lazy content did not mount');
        }
      };
      const wait=async(predicate,message)=>{
        const deadline=performance.now()+3000;
        while(!predicate()){if(performance.now()>deadline)throw Error(message);await sleep();}
      };
      if(document.querySelector('.swagger-ui')){
        const capture=()=>{
          productionSeen.push(document.body.innerText);
          for(const operation of document.querySelectorAll('.opblock')){
            const path=operation.querySelector('.opblock-summary-path')?.textContent.trim();
            if(path==='/native-shared'||path==='/native-shared-two')productionContextTexts[path]=operation.innerText;
          }
          for(const node of document.querySelectorAll('[data-busyapi-authored-value]'))if(node.getClientRects().length&&getComputedStyle(node).visibility!=='hidden'){
            const key=node.getAttribute('data-busyapi-authored-value'),values=productionValues[key]??=[];if(!values.includes(node.textContent))values.push(node.textContent);
          }
        };
        const walkDefinitions=async()=>{
          const definitions=new Set();let panels=0;
          for(;panels<128;panels++){
            await expand();capture();
            const button=[...document.querySelectorAll('[data-busyapi-definition]')].find(button=>visible(button)&&!definitions.has(button.getAttribute('data-busyapi-definition')));
            const back=button?null:[...document.querySelectorAll('button')].find(button=>visible(button)&&button.textContent.startsWith('← '));
            if(!button&&!back)break;
            const control=button||back,panel=control.closest('[data-busyapi-authored-panel]'),target=button?button.getAttribute('data-busyapi-definition'):panel?.getAttribute('data-busyapi-authored-panel');
            if(button)definitions.add(target);control.click();
            await wait(()=>panel?.isConnected&&panel.querySelector(':scope > [data-busyapi-authored-content]')?.getAttribute('data-busyapi-authored-content')===target,'Native Swagger definition/back did not mount');
          }
          if(panels>=128)throw Error('Native Swagger authored-panel walk exceeded its bounded budget');
        };
        for(let pass=0;pass<64;pass++){
          for(const branch of document.querySelectorAll('[data-busyapi-authored-branch]'))branch.open=true;
          await sleep();capture();window.scrollTo(0,(window.scrollY+500)/Math.max(1,document.documentElement.scrollHeight)>1?0:window.scrollY+500);
        }
        // Definitions in the response Schema tab must be read while that tab
        // is active, before selecting examples or callbacks hides its controls.
        await walkDefinitions();
        for(const tab of document.querySelectorAll('[role=tab]'))if(tab.isConnected&&tab.textContent==='Example Value'){tab.click();await sleep();capture();}
        for(const select of document.querySelectorAll('select')){
          if(select.options.length>32||![...select.options].every(option=>/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+(?:;|$)/i.test(option.value)))continue;
          for(const option of select.options){
            select.value=option.value;select.dispatchEvent(new Event('change',{bubbles:true}));await sleep();
            for(const tab of document.querySelectorAll('[role=tab]'))if(tab.isConnected&&tab.textContent==='Example Value')tab.click();
            await sleep();capture();
          }
        }
        for(const tab of document.querySelectorAll('.tab-header .tab-item'))if(tab.isConnected&&tab.textContent.trim()==='Callbacks')tab.click();
        await expand();capture();
        await walkDefinitions();
        window.productionSourceRoute='#/';return;
      }
      for(let iteration=0;iteration<80;iteration++){
        const route=[...routes].find(value=>!visited.has(value));if(route===undefined)break;
        visited.add(route);location.hash=route.slice(1);const definitions=new Set(),detail={route,payload:false,scroll:[]};productionRouteDetails.push(detail);
        if(route!=='#/')await wait(()=>[...document.querySelectorAll('[data-section-id]')].some(node=>node.getAttribute('data-section-id')==='/'+route.slice(2).split('#',1)[0]&&node.textContent.trim()),'Native route did not mount: '+route);
        // Navigate and verify every anchor, but walk a page's complete content
        // once. Request/response anchors do not create a new operation page or
        // justify repeating the whole lazy definition walk and scroll budget.
        const pageRoute=route.slice(2).split('#',1)[0];
        if(readPages.has(pageRoute)){
          detail.reusedPage=pageRoute;
          productionSeen.push(document.body.innerText);
          if(document.querySelector('[data-busyapi-source="%u"]'))window.productionSourceRoute=route;
          continue;
        }
        readPages.add(pageRoute);
        const capture=()=>{
          productionSeen.push(document.body.innerText);detail.payload ||= document.body.innerText.includes('payload data');
          if(pageRoute==='busyapi-operation/'+ '%s'.slice(19)||pageRoute==='busyapi-operation/'+ '%s'.slice(19)){
            const matches=[...document.querySelectorAll('[data-section-id]')].filter(node=>node.getAttribute('data-section-id')==='/'+pageRoute&&visible(node));
            productionContextNodes['/'+pageRoute]=matches.map(node=>({tag:node.tagName,html:node.outerHTML.slice(0,800),text:node.textContent.slice(0,800),inner:node.innerText,rect:[node.getBoundingClientRect().width,node.getBoundingClientRect().height]}));
            // CE leaves empty section markers as its virtual viewport moves.
            // Retain the actual visible text observed earlier on this route,
            // never replace it with a later empty marker or hidden textContent.
            const node=matches.find(node=>node.innerText?.trim());
            if(node)productionContextTexts['/'+pageRoute]=node.innerText;
          }
          for(const node of document.querySelectorAll('[data-busyapi-authored-value]'))if(node.getClientRects().length&&getComputedStyle(node).visibility!=='hidden'){
            const key=node.getAttribute('data-busyapi-authored-value'),values=productionValues[key]??=[];if(!values.includes(node.textContent))values.push(node.textContent);
          }
        };
        let panels=0;
        for(;panels<128;panels++){
          await expand();capture();
          const button=[...document.querySelectorAll('[data-busyapi-definition]')].find(button=>visible(button)&&!definitions.has(button.getAttribute('data-busyapi-definition')));
          const back=button?null:[...document.querySelectorAll('button')].find(button=>visible(button)&&button.textContent.startsWith('← '));
          if(!button&&!back)break;
          const control=button||back,panel=control.closest('[data-busyapi-authored-panel]'),target=button?button.getAttribute('data-busyapi-definition'):panel?.getAttribute('data-busyapi-authored-panel');
          if(button)definitions.add(target);control.click();
          await wait(()=>panel?.isConnected&&panel.querySelector(':scope > [data-busyapi-authored-content]')?.getAttribute('data-busyapi-authored-content')===target,'Native definition/back did not mount');
        }
        if(panels>=128)throw Error('Native authored-panel walk exceeded its bounded budget');
        for(let pass=0;pass<12;pass++){
          await sleep();await expand();
          capture();
          for(const anchor of document.querySelectorAll('a[href]')){const target=new URL(anchor.href);if(target.hash.startsWith('#/'))routes.add(target.hash);}
          if(document.querySelector('[data-busyapi-source="%u"]'))window.productionSourceRoute=route;
          // Native source controls add real rows. Exercise the lazy viewport,
          // including response/example content below those rows, as a reader
          // would; mounted operation headings alone are not a content pass.
          for(const node of [document.scrollingElement,...document.querySelectorAll('.api-content,[data-scroll-container]')])if(node)node.scrollTop+=500;
        }
        detail.scroll=[document.scrollingElement,...document.querySelectorAll('.api-content,[data-scroll-container]')].filter(Boolean).map(node=>({top:node.scrollTop,height:node.scrollHeight,client:node.clientHeight}));
      }
      if(routes.size>=80||window.productionSourceRoute===undefined)throw Error('Incomplete native route/source inventory');
    })().catch(error=>{window.productionFailure=String(error.message);}).finally(()=>{window.productionDone=true;});'started'
  )JS",observed.source_index,context_one,context_two,observed.source_index);
  evaluate(window,reader);pump_until([&]{return evaluate(window,"productionDone")=="true";},[&]{
    const auto detail=evaluate(window,"JSON.stringify({done:productionDone,failure:productionFailure,routes:productionRouteDetails,visited:[...productionVisited],pending:[...productionRoutes].filter(route=>!productionVisited.has(route)),definitions:[...document.querySelectorAll('[data-busyapi-definition]')].map(node=>node.getAttribute('data-busyapi-definition')).slice(0,16)})");
    g_test_message("Native production reader deadline: %.6000s",detail.c_str());
  });
  g_assert_true(evaluate(window,"productionFailure==='' ")=="true");
  g_autofree gchar* context_assertions=g_strdup_printf("productionContextTexts['%s']?.includes('Native one parameter owner') && !productionContextTexts['%s']?.includes('Native two parameter owner') && productionContextTexts['%s']?.includes('Native two parameter owner') && !productionContextTexts['%s']?.includes('Native one parameter owner')",swagger?"/native-shared":context_one,swagger?"/native-shared":context_one,swagger?"/native-shared-two":context_two,swagger?"/native-shared-two":context_two);
  if(evaluate(window,context_assertions)!="true")g_test_message("Native operation contexts: %.6500s",evaluate(window,"JSON.stringify({texts:productionContextTexts,nodes:productionContextNodes,owners:productionSeen.filter(text=>text.includes('Native one parameter owner')||text.includes('Native two parameter owner')).map(text=>text.slice(-1800)).slice(-3),parameters:[...document.querySelectorAll('[data-busyapi-parameter-source]')].map(node=>({pointer:node.getAttribute('data-busyapi-parameter-source'),text:node.innerText}))})").c_str());
  g_assert_true(evaluate(window,context_assertions)=="true");
  for(const char* text:{"Compatibility operation sentinel","Schema property sentinel","payload data"}){
    g_autofree gchar* check=g_strdup_printf("productionSeen.join('\\n').includes('%s')",text);
    const bool found=evaluate(window,check)=="true";
    if(!found){
      g_test_message("Missing native production fixture sentinel: %s",text);
      const auto detail=evaluate(window,"JSON.stringify({routes:productionRouteDetails,scrolls:[...document.querySelectorAll('body *')].filter(node=>node.scrollHeight>node.clientHeight+2&&['auto','scroll'].includes(getComputedStyle(node).overflowY)).slice(0,6).map(node=>({tag:node.tagName,class:node.className,top:node.scrollTop,height:node.scrollHeight,client:node.clientHeight})),seen:productionSeen.join('\\n').slice(-900)})");
      g_test_message("Native production fixture diagnostic: %.6000s",detail.c_str());
    }
    g_assert_true(found);
  }
  if(g_str_has_suffix(name,"32"))g_assert_true(evaluate(window,"['QUERY sentinel','COPY sentinel'].every(value=>productionSeen.join('\\n').includes(value))")=="true");
  g_assert_true(evaluate(window,"productionSeen.join('\\n').includes('Native callback POST sentinel')")=="true");
  g_assert_true(evaluate(window,"['Native shared Path Item sentinel','Native shared bodyless sentinel'].every(value=>productionSeen.join('\\n').includes(value))")=="true");
  g_assert_true(evaluate(window,"['Native mixed dialect operation sentinel','Native 2020 dialect schema sentinel','Native OAS dialect schema sentinel'].every(value=>productionSeen.join('\\n').includes(value))")=="true");
  if(g_str_has_suffix(name,"32")){
    g_assert_true(evaluate(window,"['Native callback QUERY sentinel','Native callback COPY sentinel','literal nested callback payload','900719925474099312345678901.00'].every(value=>productionSeen.join('\\n').includes(value))")=="true");
    g_autofree gchar* callback_path=g_build_filename(directory,name,"callback-example.txt",nullptr);
    gchar* callback_bytes=nullptr;gsize callback_length=0;
    g_file_get_contents(callback_path,&callback_bytes,&callback_length,&error);g_assert_no_error(error);
    g_autofree gchar* callback_base64=g_base64_encode(reinterpret_cast<const guchar*>(callback_bytes),callback_length);g_free(callback_bytes);
    g_autofree gchar* callback_check=g_strdup_printf("productionValues['/paths/~1things/get/callbacks/Inline/{$request.body#~1callbackUrl}/additionalOperations/COPY/responses/200/content/application~1json/examples/Captured/dataValue']?.includes(new TextDecoder().decode(Uint8Array.from(atob('%s'),value=>value.charCodeAt(0))))",callback_base64);
    g_assert_true(evaluate(window,callback_check)=="true");
  }
  // Compare the full authored data text from the production core, including
  // its retained source whitespace and numeric lexeme. A minified test string
  // would incorrectly demand normalization of this targeted source edit.
  g_autofree gchar* expected_path=g_build_filename(directory,name,"example.txt",nullptr);
  gchar* expected_bytes=nullptr;gsize expected_length=0;
  g_file_get_contents(expected_path,&expected_bytes,&expected_length,&error);g_assert_no_error(error);
  g_autofree gchar* expected_base64=g_base64_encode(reinterpret_cast<const guchar*>(expected_bytes),expected_length);g_free(expected_bytes);
  g_autofree gchar* example_check=g_strdup_printf("productionValues['/paths/~1things/get/responses/200/content/application~1json/example']?.includes(new TextDecoder().decode(Uint8Array.from(atob('%s'),value=>value.charCodeAt(0))))",expected_base64);
  g_assert_true(evaluate(window,example_check)=="true");
  for(const char* check:{
      "productionValues['/components/schemas/Precise/minimum']?.includes('9007199254740993')",
      "productionValues['/components/schemas/Precise/examples']?.includes('[9007199254740993.0]')",
      "productionValues['/paths/~1native-exact/post/requestBody/content/application~1json/example']?.includes('9007199254740993.0')"}){
    const bool exact=evaluate(window,check)=="true";
    if(!exact){
      g_test_message("Missing native exact fixture field: %s",check);
      const auto detail=evaluate(window,"JSON.stringify(productionValues).slice(-3000)");
      g_test_message("Native exact fixture diagnostic: %.3000s",detail.c_str());
    }
    g_assert_true(exact);
  }
  // Swagger's authored data tab keeps the JSON string quotes. Redoc's typed
  // Reference string field displays its decoded text. Neither is a substring
  // match or an invented serializedValue representation.
  const char* string_check=swagger?
      "productionValues['/paths/~1native-exact/post/requestBody/content/text~1plain/example']?.includes(JSON.stringify('serialized \\u96ea\\ud83d\\ude00'))":
      "productionValues['/paths/~1native-exact/post/requestBody/content/text~1plain/example']?.includes('serialized \\u96ea\\ud83d\\ude00')";
  g_assert_true(evaluate(window,string_check)=="true");
  g_assert_cmpuint(observed.blocked,==,0);
  evaluate(window,"location.hash=productionSourceRoute.slice(1);'source route'");
  g_autofree gchar* exists=g_strdup_printf("!!document.querySelector('[data-busyapi-source=\"%u\"]')",observed.source_index);
  pump_until([&]{return evaluate(window,exists)=="true";});
  g_autofree gchar* click=g_strdup_printf("document.querySelector('[data-busyapi-source=\"%u\"]').click();'clicked'",observed.source_index);
  evaluate(window,click);pump_until([&]{return observed.source==1;});
  observed.source_index=callback_index;
  g_autofree gchar* callback_exists=g_strdup_printf("!!document.querySelector('[data-busyapi-source=\"%u\"]')",callback_index);
  pump_until([&]{return evaluate(window,callback_exists)=="true";});
  g_autofree gchar* callback_click=g_strdup_printf("document.querySelector('[data-busyapi-source=\"%u\"]').click();'callback clicked'",callback_index);
  evaluate(window,callback_click);pump_until([&]{return observed.source==2;});
  g_assert_true(busyapi_documentation_window_set_outdated(window,"Outdated captured production page"));
  evaluate(window,callback_click);pump_until([&]{return observed.blocked>0;});g_assert_cmpuint(observed.source,==,2);
  busyapi_documentation_window_close(window);g_assert_cmpuint(observed.closed,==,1);g_assert_null(busyapi_documentation_window_get_view(window));
}
}  // namespace
int main(int argc,char** argv){
  // The test launcher initializes its private AT-SPI address before exec, not
  // after GTK modules/GIO threads may already have captured desktop state.
  gtk_test_init(&argc,&argv,nullptr);
  expect_confined_optional_probes();
  g_autoptr(GError) error=nullptr;
  application=gtk_application_new("io.busystack.busyapi.DocumentationTests",G_APPLICATION_NON_UNIQUE);
  g_application_register(G_APPLICATION(application),nullptr,&error);g_assert_no_error(error);
  g_test_add_func("/documentation/ordinary",ordinary);g_test_add_func("/documentation/adversarial",adversarial);
  g_test_add_func("/documentation/crash-reopen",crash_reopen);g_test_add_func("/documentation/cancel-loading",cancel_loading);
  g_test_add_func("/documentation/invalid-resources",invalid_resources);
  g_test_add_func("/documentation/ephemeral-storage",ephemeral_storage);
  g_test_add_func("/documentation/outdated-snapshot",outdated_snapshot);
  g_test_add_func("/native-logging/unexpected-warning-is-fatal",unexpected_warning_is_fatal);
  if(g_getenv("BUSYAPI_DOCUMENTATION_RENDERER_FIXTURES")){
    for(const char* name:{"swagger-31","swagger-32","redoc-31","redoc-32"}){
      g_autofree gchar* path=g_strconcat("/renderers/",name,nullptr);g_test_add_func(path,renderer_fixture);
    }
  }
  if(g_getenv("BUSYAPI_DOCUMENTATION_PRODUCTION_FIXTURES")){
    for(const char* name:{"redoc-production-30","swagger-production-20","swagger-production-30"}){
      g_autofree gchar* path=g_strconcat("/renderers/",name,nullptr);g_test_add_func(path,production_legacy_renderer_fixture);
    }
    for(const char* name:{"redoc-production-31","redoc-production-32","swagger-production-31","swagger-production-32"}){
      g_autofree gchar* path=g_strconcat("/renderers/",name,nullptr);g_test_add_func(path,production_renderer_fixture);
    }
  }
  const int status=g_test_run();
  if(optional_probes_expected) {
    g_test_assert_expected_messages();
    g_test_message("Observed %u expected upstream hardware-probe denials without granting access",static_cast<unsigned>(optional_probe_denials.size()));
  }
  g_object_unref(application);return status;
}
