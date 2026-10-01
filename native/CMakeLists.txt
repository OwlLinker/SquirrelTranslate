cmake_minimum_required(VERSION 3.20)

project(rime_translation_refresh LANGUAGES CXX OBJC)

option(BUILD_PUBLIC_PROVIDERS_ONLY
  "Build only the standalone public provider library and its source-level tests"
  OFF)

if(BUILD_PUBLIC_PROVIDERS_ONLY)
  add_library(squirrel_public_translation_providers SHARED
    src/public_translation_providers.cc
  )
  target_compile_features(squirrel_public_translation_providers PRIVATE cxx_std_17)
  target_link_libraries(squirrel_public_translation_providers PRIVATE
    "-framework CoreServices"
  )
  set_target_properties(squirrel_public_translation_providers PROPERTIES
    OUTPUT_NAME "rime-public-translation-providers"
  )
  include(CTest)
  if(BUILD_TESTING)
    add_executable(public_provider_test tests/public_provider_test.cc)
    target_compile_features(public_provider_test PRIVATE cxx_std_17)
    target_compile_options(public_provider_test PRIVATE -UNDEBUG)
    target_link_libraries(public_provider_test PRIVATE
      squirrel_public_translation_providers)
    add_test(NAME public_provider_parser COMMAND public_provider_test)
    add_executable(query_keyword_test tests/query_keyword_test.cc
      src/query_translation_service.cc)
    target_compile_features(query_keyword_test PRIVATE cxx_std_17)
    target_link_libraries(query_keyword_test PRIVATE
      squirrel_public_translation_providers)
    add_test(NAME query_keyword_translation COMMAND query_keyword_test)
  endif()
  return()
endif()

set(RIME_SOURCE_DIR "" CACHE PATH "librime source directory matching Squirrel")
set(BOOST_INCLUDE_DIR "" CACHE PATH "Boost include directory")
set(SQUIRREL_APP "/Library/Input Methods/Squirrel.app" CACHE PATH "Installed Squirrel.app")
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/translation_refresh.cc")
  set(_private_translation_default ON)
else()
  set(_private_translation_default OFF)
endif()
option(BUILD_PRIVATE_TRANSLATION_INTEGRATION
  "Build the non-public full Rime translation integration when its source exists"
  ${_private_translation_default})

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

if(BUILD_PRIVATE_TRANSLATION_INTEGRATION AND
   EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/translation_refresh.cc")
  add_library(rime_translation_refresh SHARED
    src/public_translation_providers.cc
    src/system_spell_suggestions.m
    src/query_mode_bridge.m
    src/translation_refresh.cc
  )
  target_compile_features(rime_translation_refresh PRIVATE cxx_std_17)
else()
  if(BUILD_PRIVATE_TRANSLATION_INTEGRATION)
    message(FATAL_ERROR "Private translation integration was requested but its source is absent")
  endif()
  add_library(squirrel_public_translation_providers SHARED
    src/public_translation_providers.cc
  )
  target_compile_features(squirrel_public_translation_providers PRIVATE cxx_std_17)
  target_link_libraries(squirrel_public_translation_providers PRIVATE
    "-framework CoreServices"
  )
  set_target_properties(squirrel_public_translation_providers PROPERTIES
    OUTPUT_NAME "rime-public-translation-providers"
  )
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/translation_refresh.cc")
    message(STATUS "Private translation integration disabled; building the public query bridge and provider components")
  else()
    message(STATUS "Private translation integration source is absent; building the public query bridge and provider components")
  endif()
endif()

if(BUILD_PRIVATE_TRANSLATION_INTEGRATION AND
   EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/squirrel_status_injector_probe.m")
  add_library(squirrel_status_injector_probe SHARED
    src/squirrel_status_injector_probe.m
  )
  set_target_properties(squirrel_status_injector_probe PROPERTIES
    OUTPUT_NAME "squirrel-status-injector-probe"
  )
  target_link_libraries(squirrel_status_injector_probe PRIVATE
    "-framework Foundation"
  )
endif()

add_library(squirrel_input_diagnostic SHARED
  src/squirrel_input_diagnostic.m
)

set_target_properties(squirrel_input_diagnostic PROPERTIES
  OUTPUT_NAME "squirrel-input-diagnostic"
)

target_link_libraries(squirrel_input_diagnostic PRIVATE
  "${RIME_LIBRARY}"
  "-framework AppKit"
  "-framework InputMethodKit"
)

target_include_directories(squirrel_input_diagnostic PRIVATE
  "${RIME_SOURCE_DIR}/src"
)

set_target_properties(squirrel_input_diagnostic PROPERTIES
  BUILD_WITH_INSTALL_RPATH ON
  INSTALL_RPATH "@loader_path/.."
)

add_library(squirrel_escape_guard SHARED
  src/squirrel_escape_guard.m
)

add_library(squirrel_query_bridge SHARED
  src/squirrel_query_bridge.m
  src/query_translation_service.cc
  src/public_translation_providers.cc
)

target_compile_features(squirrel_query_bridge PRIVATE cxx_std_17)

set_target_properties(squirrel_query_bridge PROPERTIES
  OUTPUT_NAME "squirrel-query-bridge"
)

target_link_libraries(squirrel_query_bridge PRIVATE
  "${RIME_LIBRARY}"
  "-framework CoreServices"
  "-framework AppKit"
  "-framework ApplicationServices"
  "-framework Carbon"
  "-framework CoreText"
)

target_include_directories(squirrel_query_bridge PRIVATE
  "${RIME_SOURCE_DIR}/src"
)

set_target_properties(squirrel_query_bridge PROPERTIES
  BUILD_WITH_INSTALL_RPATH ON
  INSTALL_RPATH "@loader_path/.."
)

set_target_properties(squirrel_escape_guard PROPERTIES
  OUTPUT_NAME "squirrel-escape-guard"
)

target_link_libraries(squirrel_escape_guard PRIVATE
  "${RIME_LIBRARY}"
  "-framework AppKit"
  "-framework InputMethodKit"
)

target_include_directories(squirrel_escape_guard PRIVATE
  "${RIME_SOURCE_DIR}/src"
)

set_target_properties(squirrel_escape_guard PROPERTIES
  BUILD_WITH_INSTALL_RPATH ON
  INSTALL_RPATH "@loader_path/.."
)

add_executable(squirrel_open_url
  src/squirrel_open_url.m
)

set_target_properties(squirrel_open_url PROPERTIES
  OUTPUT_NAME "squirrel-open-url"
)

target_link_libraries(squirrel_open_url PRIVATE
  "-framework AppKit"
  "-framework CoreServices"
)

if(TARGET rime_translation_refresh)
  target_include_directories(rime_translation_refresh PRIVATE
    "${RIME_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_BINARY_DIR}/generated"
    "${BOOST_INCLUDE_DIR}"
    "${X11_INCLUDE_DIR}"
  )
  target_compile_options(rime_translation_refresh PRIVATE
    -Wall -Wextra -Wpedantic
  )
endif()

set_source_files_properties(src/query_mode_bridge.m PROPERTIES
  COMPILE_OPTIONS "-fobjc-arc"
)

set_source_files_properties(src/squirrel_query_bridge.m PROPERTIES
  COMPILE_OPTIONS "-fobjc-arc"
)

include(CTest)
if(BUILD_TESTING)
  if(TARGET rime_translation_refresh)
    add_executable(query_mode_test tests/query_mode_test.cc)
    target_compile_features(query_mode_test PRIVATE cxx_std_17)
    target_include_directories(query_mode_test PRIVATE
      "${RIME_SOURCE_DIR}/src" "${CMAKE_CURRENT_BINARY_DIR}/generated"
      "${BOOST_INCLUDE_DIR}" "${X11_INCLUDE_DIR}"
    )
    target_compile_options(query_mode_test PRIVATE -UNDEBUG)
    target_link_libraries(query_mode_test PRIVATE rime_translation_refresh
      "${RIME_LIBRARY}" "-framework AppKit" "-framework CoreServices"
    )
    set_target_properties(query_mode_test PROPERTIES
      BUILD_RPATH "${SQUIRREL_FRAMEWORKS}"
    )
    add_test(NAME query_mode_registry COMMAND query_mode_test)
  else()
    add_executable(public_provider_test tests/public_provider_test.cc)
    target_compile_features(public_provider_test PRIVATE cxx_std_17)
    target_compile_options(public_provider_test PRIVATE -UNDEBUG)
    add_test(NAME public_provider_parser COMMAND public_provider_test)
  endif()
endif()

if(TARGET rime_translation_refresh)
  target_link_libraries(rime_translation_refresh PRIVATE
    "${RIME_LIBRARY}" "-framework AppKit" "-framework CoreServices"
    "${CMAKE_DL_LIBS}"
  )
  set_target_properties(rime_translation_refresh PROPERTIES
    OUTPUT_NAME "rime-translation-refresh"
    BUILD_WITH_INSTALL_RPATH ON
    INSTALL_RPATH "@loader_path/.."
  )
endif()
