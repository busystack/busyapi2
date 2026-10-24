# BusyAPI-owned optional window module, not a plugin/discovery boundary.
add_library(busyapi_documentation MODULE
  "${CMAKE_CURRENT_LIST_DIR}/runner/documentation_window.cc"
  "${CMAKE_CURRENT_LIST_DIR}/runner/documentation_runtime_api.cc")
apply_standard_settings(busyapi_documentation)
target_compile_features(busyapi_documentation PRIVATE cxx_std_17)
target_link_libraries(busyapi_documentation PRIVATE PkgConfig::GTK PkgConfig::WEBKIT)
set_target_properties(busyapi_documentation PROPERTIES INSTALL_RPATH "$ORIGIN")
set(BUSYAPI_DOCUMENTATION_RUNTIME_DESCRIPTOR "${CMAKE_CURRENT_BINARY_DIR}/documentation-runtime.json")
configure_file("${CMAKE_CURRENT_LIST_DIR}/documentation_runtime.json.in"
  "${BUSYAPI_DOCUMENTATION_RUNTIME_DESCRIPTOR}" @ONLY)

# Call after the ordinary bundle's clean-install step has been declared.
function(busyapi_install_documentation_runtime)
  install(TARGETS busyapi_documentation LIBRARY DESTINATION lib COMPONENT Runtime)
  install(FILES "${BUSYAPI_DOCUMENTATION_RUNTIME_DESCRIPTOR}"
    DESTINATION share/busyapi COMPONENT Runtime)
endfunction()
