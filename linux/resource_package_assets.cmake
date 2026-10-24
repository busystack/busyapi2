# This is a compiled headless core entry, not a second parser or runtime SDK.
# Every normal build mode prepares/installs it before an export can be opened.
set(BUSYAPI_RESOURCE_PACKAGE_ASSETS "${BUSYAPI_SOURCE_DIR}/build/resource-package-runtime" CACHE PATH
  "Build-time generated BusyAPI resource-package loader")
add_custom_target(busyapi_resource_package_assets ALL
  COMMAND "${Python3_EXECUTABLE}"
    "${BUSYAPI_SOURCE_DIR}/tools/prepare_resource_package_assets.py"
    --output "${BUSYAPI_RESOURCE_PACKAGE_ASSETS}"
    --dart "${BUSYAPI_NOTICE_DART}"
    --contract-runtime "${BUSYAPI_CONTRACT_ASSETS}"
    --dart-notices "${BUSYAPI_DART_NOTICES}"
  VERBATIM)
add_dependencies(busyapi_resource_package_assets busyapi_contract_assets busyapi_dart_notices)
add_dependencies(${BINARY_NAME} busyapi_resource_package_assets)
install(PROGRAMS "${BUSYAPI_RESOURCE_PACKAGE_ASSETS}/resource-package-loader"
  DESTINATION "libexec/busyapi" COMPONENT Runtime)
install(FILES "${BUSYAPI_RESOURCE_PACKAGE_ASSETS}/runtime.json"
  DESTINATION "share/busyapi/resource-package" COMPONENT Runtime)
