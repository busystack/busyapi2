// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// Modified for BusyAPI namespaces and contract authoring.
#ifndef BUSYAPI_NATIVE_SHORTCUT_METADATA_H_
#define BUSYAPI_NATIVE_SHORTCUT_METADATA_H_

#include <gtk/gtk.h>
#include <cstring>

inline gchar* gtk_accelerator_from_binding_metadata(const gchar* shortcut) {
  if (shortcut == nullptr || shortcut[0] == '\0') {
    return nullptr;
  }

  // Dart sends logical Unicode identity, never a translated shortcut badge.
  // GDK supplies legacy keysym names such as eacute or Cyrillic_a.
  const gchar* unicode = strstr(shortcut, "U+");
  if (unicode != nullptr) {
    const gchar* digits = unicode + 2;
    const gsize count = strlen(digits);
    if (count == 0 || count > 6 ||
        strspn(digits, "0123456789abcdefABCDEF") != count) {
      return nullptr;
    }
    const guint64 codepoint = g_ascii_strtoull(digits, nullptr, 16);
    if (codepoint == 0 || codepoint > 0x10ffff ||
        !g_unichar_validate(codepoint)) {
      return nullptr;
    }
    g_autofree gchar* prefix = g_strndup(shortcut, unicode - shortcut);
    g_autofree gchar* sample = g_strconcat(prefix, "a", nullptr);
    guint sample_key = 0;
    GdkModifierType modifiers = static_cast<GdkModifierType>(0);
    gtk_accelerator_parse(sample, &sample_key, &modifiers);
    if (sample_key != GDK_KEY_a) return nullptr;
    // GTK normalizes alphabetic accelerator keys to lowercase. Shift remains
    // a separate modifier, as it is in the structured application binding.
    const guint expected_key = gdk_keyval_to_lower(
        gdk_unicode_to_keyval(codepoint));
    g_autofree gchar* canonical = gtk_accelerator_name(expected_key, modifiers);
    guint verified = 0;
    GdkModifierType verified_modifiers = static_cast<GdkModifierType>(0);
    gtk_accelerator_parse(canonical, &verified, &verified_modifiers);
    // Some Unicode keys have no GTK 3 accelerator name. The caller retains the
    // truthful display label instead of publishing invalid accelerator syntax.
    return verified == expected_key && verified_modifiers == modifiers
               ? g_strdup(canonical)
               : nullptr;
  }

  guint key = 0;
  GdkModifierType modifiers = static_cast<GdkModifierType>(0);
  gtk_accelerator_parse(shortcut, &key, &modifiers);
  if (key != 0) {
    return g_strdup(shortcut);
  }

  return nullptr;
}

#endif
