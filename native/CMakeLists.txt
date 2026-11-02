cmake_minimum_required(VERSION 3.16)
project(airplaybridge C CXX OBJCXX)

if(NOT APPLE)
  message(FATAL_ERROR "airplaybridge currently only supports macOS")
endif()

set(CMAKE_C_STANDARD 99)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_FLAGS "-O2 ${CMAKE_C_FLAGS}")

# Homebrew pkg-config paths (arm64 + intel + keg-only openssl)
set(ENV{PKG_CONFIG_PATH} "/opt/homebrew/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/opt/openssl@3/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")

find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED
  gstreamer-1.0>=1.20
  gstreamer-app-1.0
  gstreamer-video-1.0
  gstreamer-sdp-1.0
  glib-2.0
  gobject-2.0)
pkg_check_modules(PLIST REQUIRED libplist-2.0)
pkg_check_modules(OPENSSL_PC REQUIRED openssl>=3.0.0)

message(STATUS "GStreamer ${GST_VERSION}, libplist ${PLIST_VERSION}, openssl ${OPENSSL_PC_VERSION}")

# ---- UxPlay core (vendored, GPLv3/LGPL-2.1+) -------------------------------

file(GLOB UXPLAY_LIB_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/uxplay/lib/*.c)

set(UXPLAY_SOURCES
  ${UXPLAY_LIB_SOURCES}
  uxplay/lib/dns_sd/dns_sd.c
  uxplay/lib/llhttp/api.c
  uxplay/lib/llhttp/http.c
  uxplay/lib/llhttp/llhttp.c
  uxplay/lib/playfair/hand_garble.c
  uxplay/lib/playfair/modified_md5.c
  uxplay/lib/playfair/omg_hax.c
  uxplay/lib/playfair/playfair.c
  uxplay/lib/playfair/sap_hash.c
  uxplay/renderers/audio_renderer.c
  uxplay/renderers/video_renderer.c
)

add_library(uxplaycore STATIC ${UXPLAY_SOURCES})

target_include_directories(uxplaycore PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/uxplay/lib
  ${CMAKE_CURRENT_SOURCE_DIR}/uxplay/lib/playfair
  ${CMAKE_CURRENT_SOURCE_DIR}/uxplay/lib/llhttp
  ${CMAKE_CURRENT_SOURCE_DIR}/uxplay/renderers
  ${GST_INCLUDE_DIRS}
  ${PLIST_INCLUDE_DIRS}
  ${OPENSSL_PC_INCLUDE_DIRS}
)

# mirrors UxPlay's own build flags for Apple + Bonjour discovery
target_compile_definitions(uxplaycore PUBLIC NOHOLD EXTERNAL_DNS_SD)
if(PLIST_VERSION VERSION_GREATER_EQUAL 2.1.0)
  target_compile_definitions(uxplaycore PUBLIC PLIST_210)
endif()
if(PLIST_VERSION VERSION_GREATER_EQUAL 2.3.0)
  target_compile_definitions(uxplaycore PUBLIC PLIST_230)
endif()

target_link_directories(uxplaycore PUBLIC ${GST_LIBRARY_DIRS} ${PLIST_LIBRARY_DIRS} ${OPENSSL_PC_LIBRARY_DIRS})
target_link_libraries(uxplaycore PUBLIC
  ${GST_LINK_LIBRARIES}
  ${PLIST_LINK_LIBRARIES}
  ${OPENSSL_PC_LINK_LIBRARIES}
  pthread
)

# ---- bridge shared library --------------------------------------------------

add_library(airplaybridge SHARED airplay_bridge.mm)
target_include_directories(airplaybridge PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${GST_INCLUDE_DIRS}
)
target_link_libraries(airplaybridge PRIVATE uxplaycore "-framework Cocoa")
set_target_properties(airplaybridge PROPERTIES
  OUTPUT_NAME "airplaybridge"
  PREFIX "lib"
)
