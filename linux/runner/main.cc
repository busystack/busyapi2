// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// BusyAPI namespaces; unrelated integrations removed.
#include "my_application.h"

int main(int argc, char** argv) {
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
