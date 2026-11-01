# Fonts have asset-specific licences, independent of the widget-code licence.
# Inspect current Flutter output; retain the original no-subsetting baseline.
set(BUSYAPI_FONT_NOTICES "${BUSYAPI_SOURCE_DIR}/build/font-notices" CACHE PATH
  "Build-time generated BusyAPI font notices")
add_custom_target(busyapi_font_notices ALL
  COMMAND "${BUSYAPI_NOTICE_DART}"
    "--packages=${BUSYAPI_SOURCE_DIR}/.dart_tool/package_config.json"
    "${BUSYAPI_SOURCE_DIR}/packages/busyapi_core/tool/prepare_notices.dart"
    "--font-assets=${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
    "--output=${BUSYAPI_FONT_NOTICES}"
  VERBATIM)
# Ninja precreates byproduct parent directories. Atomic publication must own
# initial directory creation; this ALL target verifies its output every build.
add_dependencies(busyapi_font_notices flutter_assemble)
add_dependencies(${BINARY_NAME} busyapi_font_notices)
install(DIRECTORY "${BUSYAPI_FONT_NOTICES}/"
  DESTINATION "share/licenses/busyapi-fonts"
  COMPONENT Runtime)
