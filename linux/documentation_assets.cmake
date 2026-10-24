# Optional documentation engines are local immutable assets in every build
# mode. No renderer, npm installation or network access runs on project open.
set(BUSYAPI_DOCUMENTATION_ASSETS "${BUSYAPI_SOURCE_DIR}/build/documentation-runtime")
add_custom_target(busyapi_documentation_assets ALL
  COMMAND "${BUSYAPI_CONTRACT_ASSETS}/node"
    "${BUSYAPI_SOURCE_DIR}/tools/prepare_documentation_assets.mjs"
    --output "${BUSYAPI_DOCUMENTATION_ASSETS}/redoc"
  COMMAND "${BUSYAPI_CONTRACT_ASSETS}/node"
    "${BUSYAPI_SOURCE_DIR}/tools/prepare_documentation_assets.mjs"
    --output "${BUSYAPI_DOCUMENTATION_ASSETS}/swagger" --preset swagger
  BYPRODUCTS "${BUSYAPI_DOCUMENTATION_ASSETS}/redoc/assets.json"
    "${BUSYAPI_DOCUMENTATION_ASSETS}/redoc/redoc.js"
    "${BUSYAPI_DOCUMENTATION_ASSETS}/redoc/bootstrap.js"
    "${BUSYAPI_DOCUMENTATION_ASSETS}/redoc/THIRD_PARTY_NOTICES.txt"
    "${BUSYAPI_DOCUMENTATION_ASSETS}/redoc/third-party.json"
    "${BUSYAPI_DOCUMENTATION_ASSETS}/swagger/assets.json"
    "${BUSYAPI_DOCUMENTATION_ASSETS}/swagger/swagger.js"
    "${BUSYAPI_DOCUMENTATION_ASSETS}/swagger/swagger.css"
    "${BUSYAPI_DOCUMENTATION_ASSETS}/swagger/bootstrap.js"
    "${BUSYAPI_DOCUMENTATION_ASSETS}/swagger/THIRD_PARTY_NOTICES.txt"
    "${BUSYAPI_DOCUMENTATION_ASSETS}/swagger/third-party.json"
    "${BUSYAPI_DOCUMENTATION_ASSETS}/swagger/swagger-ui-es-bundle-core.js.LICENSE.txt"
  VERBATIM)
add_dependencies(busyapi_documentation_assets busyapi_contract_assets)
add_dependencies(${BINARY_NAME} busyapi_documentation_assets)
install(DIRECTORY "${BUSYAPI_DOCUMENTATION_ASSETS}/redoc/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/share/busyapi/documentation/redoc" COMPONENT Runtime)
install(FILES
  "${BUSYAPI_DOCUMENTATION_ASSETS}/redoc/THIRD_PARTY_NOTICES.txt"
  "${BUSYAPI_DOCUMENTATION_ASSETS}/redoc/third-party.json"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/share/licenses/busyapi-documentation/redoc" COMPONENT Runtime)
install(DIRECTORY "${BUSYAPI_DOCUMENTATION_ASSETS}/swagger/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/share/busyapi/documentation/swagger" COMPONENT Runtime)
install(FILES
  "${BUSYAPI_DOCUMENTATION_ASSETS}/swagger/THIRD_PARTY_NOTICES.txt"
  "${BUSYAPI_DOCUMENTATION_ASSETS}/swagger/third-party.json"
  "${BUSYAPI_DOCUMENTATION_ASSETS}/swagger/swagger-ui-es-bundle-core.js.LICENSE.txt"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/share/licenses/busyapi-documentation/swagger" COMPONENT Runtime)
