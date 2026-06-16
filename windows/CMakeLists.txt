cmake_minimum_required(VERSION 3.14)
project(mssql_connection_plugin LANGUAGES CXX)

set(PROJECT_NAME "mssql_connection_plugin")

add_library(${PROJECT_NAME} SHARED
  "mssql_connection_plugin.cpp"
)

target_compile_definitions(${PROJECT_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PROJECT_NAME} PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PROJECT_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
)

# Bundle the FreeTDS and OpenSSL DLLs with the plugin for Flutter Windows build system
set(mssql_connection_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/bin/sybdb.dll"
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/bin/ct.dll"
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/bin/libcrypto-1_1-x64.dll"
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/bin/libssl-1_1-x64.dll"
  PARENT_SCOPE
)

set(mssql_connection_plugin_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/bin/sybdb.dll"
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/bin/ct.dll"
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/bin/libcrypto-1_1-x64.dll"
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/bin/libssl-1_1-x64.dll"
  PARENT_SCOPE
)
