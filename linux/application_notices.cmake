# The compiler's own receipt is matched to the current output; no package
# installation, code execution or home-directory convention is used here.
set(BUSYAPI_APPLICATION_NOTICES "${BUSYAPI_SOURCE_DIR}/build/application-notices" CACHE PATH
  "Build-time generated BusyAPI Flutter/plugin notices and covered source")
get_directory_property(BUSYAPI_NOTICE_ENVIRONMENT DIRECTORY "${FLUTTER_MANAGED_DIR}"
  DEFINITION FLUTTER_TOOL_ENVIRONMENT)
foreach(BUSYAPI_NOTICE_VARIABLE IN LISTS BUSYAPI_NOTICE_ENVIRONMENT)
  if(BUSYAPI_NOTICE_VARIABLE MATCHES "^FLUTTER_TARGET=(.+)$")
    set(BUSYAPI_NOTICE_ENTRY "${CMAKE_MATCH_1}")
  endif()
endforeach()
if(NOT BUSYAPI_NOTICE_ENTRY)
  set(BUSYAPI_NOTICE_ENTRY "lib/main.dart")
endif()
if(CMAKE_BUILD_TYPE MATCHES "Debug")
  set(BUSYAPI_NOTICE_APPLICATION "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}/kernel_blob.bin")
else()
  set(BUSYAPI_NOTICE_APPLICATION "${AOT_LIBRARY}")
endif()
get_filename_component(BUSYAPI_NOTICE_APPLICATION "${BUSYAPI_NOTICE_APPLICATION}" ABSOLUTE)
add_custom_target(busyapi_application_notices ALL
  COMMAND "${BUSYAPI_NOTICE_DART}"
    "--packages=${BUSYAPI_SOURCE_DIR}/.dart_tool/package_config.json"
    "${BUSYAPI_SOURCE_DIR}/packages/busyapi_core/tool/prepare_notices.dart"
    "--application=${BUSYAPI_NOTICE_APPLICATION}"
    "--mode=${CMAKE_BUILD_TYPE}" "--entry=${BUSYAPI_NOTICE_ENTRY}"
    "--output=${BUSYAPI_APPLICATION_NOTICES}"
  VERBATIM)
# As with other atomic notice targets, do not declare nested byproducts: Ninja
# must not precreate an unowned publication directory. Verify on every build.
add_dependencies(busyapi_application_notices flutter_assemble)
add_dependencies(${BINARY_NAME} busyapi_application_notices)
install(DIRECTORY "${BUSYAPI_APPLICATION_NOTICES}/"
  DESTINATION "share/licenses/busyapi-application"
  COMPONENT Runtime)
