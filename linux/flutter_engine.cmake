# Exact BusyAPI-patched Flutter engine; never modify shared SDK artifacts.
# GTK and the user's installed input-method services remain unmodified.
set(BUSYAPI_FLUTTER_ENGINE_HOME "${BUSYAPI_SOURCE_DIR}/build/flutter-engine")
if(DEFINED ENV{BUSYAPI_FLUTTER_ENGINE_HOME})
  set(BUSYAPI_FLUTTER_ENGINE_HOME "$ENV{BUSYAPI_FLUTTER_ENGINE_HOME}")
endif()
string(TOLOWER "${CMAKE_BUILD_TYPE}" BUSYAPI_FLUTTER_ENGINE_MODE)
if(EXISTS "${BUSYAPI_FLUTTER_ENGINE_HOME}/host_${BUSYAPI_FLUTTER_ENGINE_MODE}/busyapi-engine.json")
  get_directory_property(BUSYAPI_FLUTTER_SDK DIRECTORY "${FLUTTER_MANAGED_DIR}" DEFINITION FLUTTER_ROOT)
  set(BUSYAPI_VERIFY_ENGINE "${BUSYAPI_SOURCE_DIR}/tools/verify_flutter_engine.py")
  add_custom_target(busyapi_verify_flutter_engine ALL
    COMMAND "${Python3_EXECUTABLE}" "${BUSYAPI_VERIFY_ENGINE}"
      --home "${BUSYAPI_FLUTTER_ENGINE_HOME}" --mode "${BUSYAPI_FLUTTER_ENGINE_MODE}"
      --sdk "${BUSYAPI_FLUTTER_SDK}" VERBATIM)
  add_dependencies(${BINARY_NAME} busyapi_verify_flutter_engine)
  # Install after the SDK library. Verify again at publication, so replacing a
  # cached input after configuration cannot silently ship a different engine.
  install(CODE "
    execute_process(COMMAND \"${Python3_EXECUTABLE}\" \"${BUSYAPI_VERIFY_ENGINE}\"
      --home \"${BUSYAPI_FLUTTER_ENGINE_HOME}\" --mode \"${BUSYAPI_FLUTTER_ENGINE_MODE}\"
      --sdk \"${BUSYAPI_FLUTTER_SDK}\" RESULT_VARIABLE result)
    if(NOT result EQUAL 0)
      message(FATAL_ERROR \"BusyAPI Flutter engine verification failed\")
    endif()
  " COMPONENT Runtime)
  install(FILES "${BUSYAPI_FLUTTER_ENGINE_HOME}/host_${BUSYAPI_FLUTTER_ENGINE_MODE}/libflutter_linux_gtk.so"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
  # host_MODE is an atomic stage-selection symlink. Publish its files, never
  # that build-time link. Repair earlier bundle installations without following
  # their link back into the immutable input stage.
  install(CODE "
    set(engine_notices \"\$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/share/busyapi/flutter-engine\")
    if(IS_SYMLINK \"\${engine_notices}\")
      file(REMOVE \"\${engine_notices}\")
    endif()
  " COMPONENT Runtime)
  install(FILES
    "${BUSYAPI_FLUTTER_ENGINE_HOME}/host_${BUSYAPI_FLUTTER_ENGINE_MODE}/busyapi-engine.json"
    "${BUSYAPI_FLUTTER_ENGINE_HOME}/host_${BUSYAPI_FLUTTER_ENGINE_MODE}/linux-input-ordering.patch"
    "${BUSYAPI_FLUTTER_ENGINE_HOME}/host_${BUSYAPI_FLUTTER_ENGINE_MODE}/FLUTTER-LICENSE"
    "${BUSYAPI_FLUTTER_ENGINE_HOME}/host_${BUSYAPI_FLUTTER_ENGINE_MODE}/ENGINE-LICENSE"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/share/busyapi/flutter-engine" COMPONENT Runtime)
else()
  message(FATAL_ERROR "Prepare BusyAPI's pinned ${BUSYAPI_FLUTTER_ENGINE_MODE} Flutter engine with tools/build_flutter_engine.py and tools/prepare_flutter_engine.py. The shared SDK engine cannot substitute for the ordered-input correction. See README.md.")
endif()
