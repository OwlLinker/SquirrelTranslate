cmake_minimum_required(VERSION 3.20)

project(rime_translation_refresh LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(RIME_SOURCE_DIR "" CACHE PATH "librime source directory matching Squirrel")
set(BOOST_INCLUDE_DIR "" CACHE PATH "Boost include directory")
set(SQUIRREL_APP "/Library/Input Methods/Squirrel.app" CACHE PATH "Installed Squirrel.app")

if(NOT EXISTS "${RIME_SOURCE_DIR}/src/rime/context.h")
  message(FATAL_ERROR "RIME_SOURCE_DIR must point to a librime source tree")
endif()

if(NOT EXISTS "${BOOST_INCLUDE_DIR}/boost/signals2/signal.hpp")
  message(FATAL_ERROR "BOOST_INCLUDE_DIR must contain Boost headers")
endif()

find_path(X11_INCLUDE_DIR NAMES X11/keysym.h)
if(NOT X11_INCLUDE_DIR)
  message(FATAL_ERROR "Cannot find X11/keysym.h required by librime key events")
endif()

set(SQUIRREL_FRAMEWORKS "${SQUIRREL_APP}/Contents/Frameworks")
set(RIME_LIBRARY "${SQUIRREL_FRAMEWORKS}/librime.1.dylib")
if(NOT EXISTS "${RIME_LIBRARY}")
  message(FATAL_ERROR "Cannot find ${RIME_LIBRARY}")
endif()

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated/rime")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/generated/rime/build_config.h"
  "#ifndef RIME_BUILD_CONFIG_H_\n#define RIME_BUILD_CONFIG_H_\n#endif\n")

add_library(rime_translation_refresh SHARED
  src/translation_refresh.cc
)

target_include_directories(rime_translation_refresh PRIVATE
  "${RIME_SOURCE_DIR}/src"
  "${CMAKE_CURRENT_BINARY_DIR}/generated"
  "${BOOST_INCLUDE_DIR}"
  "${X11_INCLUDE_DIR}"
)

target_compile_options(rime_translation_refresh PRIVATE
  -Wall
  -Wextra
  -Wpedantic
)

target_link_libraries(rime_translation_refresh PRIVATE
  "${RIME_LIBRARY}"
  "-framework CoreServices"
)

set_target_properties(rime_translation_refresh PROPERTIES
  OUTPUT_NAME "rime-translation-refresh"
  BUILD_WITH_INSTALL_RPATH ON
  INSTALL_RPATH "@loader_path/.."
)
