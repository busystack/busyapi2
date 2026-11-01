# Every Flutter/IDE build installs the executable-relative contract runtime.
# Preparation is offline and uses only explicitly provisioned, locked inputs.
find_package(Python3 REQUIRED COMPONENTS Interpreter)
get_filename_component(BUSYAPI_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(BUSYAPI_CONTRACT_ASSETS "${BUSYAPI_SOURCE_DIR}/build/contract-runtime")
set(BUSYAPI_M3_TOOL_ASSETS "${BUSYAPI_SOURCE_DIR}/build/m3-tools")
add_custom_target(busyapi_contract_assets ALL
  COMMAND "${Python3_EXECUTABLE}"
    "${BUSYAPI_SOURCE_DIR}/tools/prepare_contract_assets.py"
    --output "${BUSYAPI_CONTRACT_ASSETS}"
  BYPRODUCTS "${BUSYAPI_CONTRACT_ASSETS}/node"
    "${BUSYAPI_CONTRACT_ASSETS}/engine.cjs"
    "${BUSYAPI_CONTRACT_ASSETS}/mock-server.cjs"
    "${BUSYAPI_CONTRACT_ASSETS}/policy-worker.cjs"
    "${BUSYAPI_CONTRACT_ASSETS}/policy-isolation.node"
    "${BUSYAPI_CONTRACT_ASSETS}/policy-launcher"
    "${BUSYAPI_CONTRACT_ASSETS}/policy-build.json"
  VERBATIM)
add_dependencies(${BINARY_NAME} busyapi_contract_assets)
add_custom_target(busyapi_m3_tool_assets ALL
  COMMAND "${Python3_EXECUTABLE}"
    "${BUSYAPI_SOURCE_DIR}/tools/prepare_m3_tools.py"
    --output "${BUSYAPI_M3_TOOL_ASSETS}"
  BYPRODUCTS "${BUSYAPI_M3_TOOL_ASSETS}/oasdiff"
    "${BUSYAPI_M3_TOOL_ASSETS}/tools.json"
  VERBATIM)
add_dependencies(${BINARY_NAME} busyapi_m3_tool_assets)

install(PROGRAMS "${BUSYAPI_CONTRACT_ASSETS}/node"
  "${BUSYAPI_CONTRACT_ASSETS}/policy-launcher"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/libexec/busyapi" COMPONENT Runtime)
install(PROGRAMS "${BUSYAPI_M3_TOOL_ASSETS}/oasdiff"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/libexec/busyapi" COMPONENT Runtime)
install(FILES "${BUSYAPI_CONTRACT_ASSETS}/engine.cjs"
  "${BUSYAPI_CONTRACT_ASSETS}/build.json"
  "${BUSYAPI_CONTRACT_ASSETS}/mock-server.cjs"
  "${BUSYAPI_CONTRACT_ASSETS}/policy-worker.cjs"
  "${BUSYAPI_CONTRACT_ASSETS}/policy-isolation.node"
  "${BUSYAPI_CONTRACT_ASSETS}/policy-build.json"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/libexec/busyapi" COMPONENT Runtime)
install(DIRECTORY "${BUSYAPI_CONTRACT_ASSETS}/schemas/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/share/busyapi/schemas" COMPONENT Runtime)
install(DIRECTORY "${BUSYAPI_CONTRACT_ASSETS}/licenses/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/share/licenses/busyapi-engine" COMPONENT Runtime)
install(FILES "${BUSYAPI_M3_TOOL_ASSETS}/tools.json"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/share/busyapi" COMPONENT Runtime)
install(DIRECTORY "${BUSYAPI_M3_TOOL_ASSETS}/licenses/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/share/licenses/busyapi-tools" COMPONENT Runtime)

include("${CMAKE_CURRENT_LIST_DIR}/documentation_assets.cmake")

# Explicitly prepared official JAR/JRE; no application-time provisioning.
set(BUSYAPI_GENERATOR_ASSETS "${BUSYAPI_SOURCE_DIR}/build/generator")
add_custom_target(busyapi_generator_assets ALL
  COMMAND "${Python3_EXECUTABLE}" "${BUSYAPI_SOURCE_DIR}/tools/prepare_generator.py"
    --output "${BUSYAPI_GENERATOR_ASSETS}"
  VERBATIM)
add_dependencies(${BINARY_NAME} busyapi_generator_assets)
install(DIRECTORY "${BUSYAPI_GENERATOR_ASSETS}/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/libexec/busyapi/generator"
  USE_SOURCE_PERMISSIONS COMPONENT Runtime)
install(DIRECTORY "${BUSYAPI_GENERATOR_ASSETS}/notices/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/share/licenses/busyapi-generator" COMPONENT Runtime)
install(DIRECTORY "${BUSYAPI_GENERATOR_ASSETS}/jre/legal/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/share/licenses/busyapi-generator/jre-legal" COMPONENT Runtime)
