// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// BusyAPI namespaces; unrelated integrations removed.
#ifndef RUNNER_GTK_WINDOW_PREFERENCES_H_
#define RUNNER_GTK_WINDOW_PREFERENCES_H_

#include <gtk/gtk.h>

#include <array>
#include <functional>
#include <string>

struct BusyApiGtkWindowPreferences {
  std::string decoration_layout;
  std::string double_click;
  std::string middle_click;
  std::string right_click;
};

class BusyApiGtkWindowPreferencesWatcher {
 public:
  using ChangedCallback =
      std::function<void(const BusyApiGtkWindowPreferences&)>;

  explicit BusyApiGtkWindowPreferencesWatcher(GtkSettings* settings = nullptr);
  ~BusyApiGtkWindowPreferencesWatcher();

  BusyApiGtkWindowPreferencesWatcher(
      const BusyApiGtkWindowPreferencesWatcher&) = delete;
  BusyApiGtkWindowPreferencesWatcher& operator=(
      const BusyApiGtkWindowPreferencesWatcher&) = delete;

  BusyApiGtkWindowPreferences Read() const;
  static BusyApiGtkWindowPreferences Defaults();
  bool Start(ChangedCallback callback);
  void Stop();

  std::array<gulong, 4> signal_ids() const;

 private:
  static void OnSettingChanged(GObject* object,
                               GParamSpec* specification,
                               gpointer user_data);
  GtkSettings* ResolveSettings() const;

  GtkSettings* settings_;
  ChangedCallback callback_;
  std::array<gulong, 4> signal_ids_ = {0, 0, 0, 0};
};

#endif  // RUNNER_GTK_WINDOW_PREFERENCES_H_
