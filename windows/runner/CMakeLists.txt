cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "../native/window_control/window_control_plugin.cpp"
  "../native/zerotier/zerotier_windows_adapter_bridge.cpp"
  "../native/zerotier/zerotier_windows_firewall_manager.cpp"
  "../native/zerotier/zerotier_windows_network_manager.cpp"
  "../native/zerotier/zerotier_windows_privileged_mount_ipc.cpp"
  "../native/zerotier/zerotier_windows_plugin.cpp"
  "../native/zerotier/zerotier_windows_runtime.cpp"
  "../native/zerotier/zerotier_windows_tap_backend.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

add_executable(zt_runtime_smoke
  "../native/zerotier/zerotier_windows_adapter_bridge.cpp"
  "../native/zerotier/zerotier_windows_network_manager.cpp"
  "../native/zerotier/zerotier_windows_privileged_mount_ipc.cpp"
  "../native/zerotier/zerotier_windows_runtime.cpp"
  "../native/zerotier/zerotier_windows_tap_backend.cpp"
  "../native/zerotier/zt_runtime_smoke.cpp"
)

add_executable(zt_mount_service
  "../native/zerotier/zerotier_windows_privileged_mount_ipc.cpp"
  "../native/zerotier/zt_mount_service_main.cpp"
)
set_target_properties(zt_mount_service PROPERTIES OUTPUT_NAME "zt_mount_helper_v6")

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
apply_standard_settings(zt_runtime_smoke)
apply_standard_settings(zt_mount_service)

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_compile_definitions(zt_runtime_smoke PRIVATE "NOMINMAX")
target_compile_definitions(zt_mount_service PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app flutter_wrapper_plugin)
target_link_libraries(${BINARY_NAME} PRIVATE
  "dwmapi.lib"
  "iphlpapi.lib"
  "ole32.lib"
  "oleaut32.lib"
  "ws2_32.lib"
  zt-shared
)
target_link_libraries(zt_runtime_smoke PRIVATE
  "iphlpapi.lib"
  "ws2_32.lib"
  zt-shared
)
target_link_libraries(zt_mount_service PRIVATE
  "advapi32.lib"
  "iphlpapi.lib"
  "ws2_32.lib"
)
target_include_directories(${BINARY_NAME} PRIVATE
  "${CMAKE_SOURCE_DIR}"
  "${CMAKE_SOURCE_DIR}/../third_party/libzt/include"
)
target_include_directories(zt_runtime_smoke PRIVATE
  "${CMAKE_SOURCE_DIR}"
  "${FLUTTER_MANAGED_DIR}/ephemeral/cpp_client_wrapper/include"
  "${CMAKE_SOURCE_DIR}/../third_party/libzt/include"
)
target_include_directories(zt_mount_service PRIVATE
  "${CMAKE_SOURCE_DIR}"
)

set(WINTUN_DLL_PATH
  "${CMAKE_SOURCE_DIR}/../third_party/wintun/0.14.1/extract/wintun/bin/amd64/wintun.dll"
)

add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    $<TARGET_FILE:zt-shared>
    $<TARGET_FILE_DIR:${BINARY_NAME}>
  VERBATIM
)

add_custom_command(TARGET zt_runtime_smoke POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    $<TARGET_FILE:zt-shared>
    $<TARGET_FILE_DIR:zt_runtime_smoke>
  VERBATIM
)

if(EXISTS "${WINTUN_DLL_PATH}")
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${WINTUN_DLL_PATH}"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/wintun.dll"
    VERBATIM
  )
  add_custom_command(TARGET zt_runtime_smoke POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${WINTUN_DLL_PATH}"
      "$<TARGET_FILE_DIR:zt_runtime_smoke>/wintun.dll"
    VERBATIM
  )
else()
  message(WARNING "wintun.dll not found at ${WINTUN_DLL_PATH}; Wintun adapter bootstrap may fail.")
endif()

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
