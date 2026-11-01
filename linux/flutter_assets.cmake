# Keep the approved icon fonts intact in every normal Flutter/CMake launch.
# In the pinned SDK an incremental Linux assets target can retain a prior icon
# subset after app.dill changes (new, reachable Yaru glyphs are then missing).
# Use the SDK's supported build option, not altered SDK/vendor font files or a
# post-build repair. This does not change the selected Flutter engine.
list(FILTER FLUTTER_TOOL_ENVIRONMENT EXCLUDE REGEX "^TREE_SHAKE_ICONS=")
list(APPEND FLUTTER_TOOL_ENVIRONMENT "TREE_SHAKE_ICONS=false")
