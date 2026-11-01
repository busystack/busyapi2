# Flutter's normal install rules own the engine library. Bind the installed
# bytes to the selected upstream SDK/cache without replacing that library.
get_directory_property(BUSYAPI_FLUTTER_SDK DIRECTORY "${FLUTTER_MANAGED_DIR}" DEFINITION FLUTTER_ROOT)
string(TOLOWER "${CMAKE_BUILD_TYPE}" BUSYAPI_FLUTTER_SDK_MODE)
set(BUSYAPI_SDK_VERIFY "${BUSYAPI_SOURCE_DIR}/tools/verify_flutter_sdk.py")
set(BUSYAPI_SDK_RECEIPT "${CMAKE_CURRENT_BINARY_DIR}/busyapi-flutter-sdk.json")
add_custom_target(busyapi_verify_flutter_sdk ALL
  COMMAND "${Python3_EXECUTABLE}" "${BUSYAPI_SDK_VERIFY}"
    --sdk "${BUSYAPI_FLUTTER_SDK}" --mode "${BUSYAPI_FLUTTER_SDK_MODE}"
    --library "${FLUTTER_LIBRARY}" --receipt "${BUSYAPI_SDK_RECEIPT}"
  VERBATIM)
add_dependencies(busyapi_verify_flutter_sdk flutter_assemble)
add_dependencies(${BINARY_NAME} busyapi_verify_flutter_sdk)
install(CODE "
  execute_process(COMMAND \"${Python3_EXECUTABLE}\" \"${BUSYAPI_SDK_VERIFY}\"
    --sdk \"${BUSYAPI_FLUTTER_SDK}\" --mode \"${BUSYAPI_FLUTTER_SDK_MODE}\"
    --library \"${FLUTTER_LIBRARY}\" --receipt \"${BUSYAPI_SDK_RECEIPT}\" --check-receipt
    RESULT_VARIABLE result)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR \"Upstream Flutter SDK inputs changed before installation\")
  endif()
" COMPONENT Runtime)
install(FILES "${BUSYAPI_SDK_RECEIPT}" DESTINATION "share/busyapi"
  RENAME "flutter-sdk.json" COMPONENT Runtime)
