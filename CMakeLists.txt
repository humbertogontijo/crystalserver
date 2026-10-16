cmake_minimum_required(VERSION 3.22 FATAL_ERROR)

# Drop empty preset passthroughs so a monorepo checkout can fill repo-local
# defaults. Standalone CI leaves a real CCACHE_DIR / NuGet source untouched.
foreach(_idleot_env_var
        VCPKG_DEFAULT_BINARY_CACHE
        VCPKG_BINARY_SOURCES
        VCPKG_DOWNLOADS
        CCACHE_DIR
        CCACHE_BASEDIR
        CCACHE_NOHASHDIR)
    if("$ENV{${_idleot_env_var}}" STREQUAL "")
        unset(ENV{${_idleot_env_var}})
    endif()
endforeach()
include("${CMAKE_CURRENT_SOURCE_DIR}/../../scripts/idleot-build-cache.cmake" OPTIONAL)

# VCPKG
# cmake -DCMAKE_TOOLCHAIN_FILE=/opt/workspace/vcpkg/scripts/buildsystems/vcpkg.cmake ..
# Needed libs are in file vcpkg.json
# Windows required libs: .\vcpkg install --triplet x64-windows asio pugixml spdlog curl protobuf parallel-hashmap magic-enum mio luajit libmariadb mpir abseil bshoshany-thread-pool

if(DEFINED ENV{VCPKG_ROOT} AND NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"
            CACHE STRING "")
endif()

if(DEFINED ENV{VCPKG_DEFAULT_TRIPLET} AND NOT DEFINED VCPKG_TARGET_TRIPLET)
    set(VCPKG_TARGET_TRIPLET "$ENV{VCPKG_DEFAULT_TRIPLET}" CACHE STRING "")
endif()

set(VCPKG_FEATURE_FLAGS "versions")
set(VCPKG_BUILD_TYPE "release")
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# *****************************************************************************
# Project crystalserver
# *****************************************************************************
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    project(crystalserver-debug LANGUAGES CXX)
else()
    project(crystalserver LANGUAGES CXX)
endif()

# *****************************************************************************
# Append cmake search path
# *****************************************************************************
list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules)

# Configure build options for compatibility with commodity CPUs
if(NOT MSVC AND CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64|i[3-6]86)$")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -march=x86-64 -mtune=generic -mno-avx -mno-sse4")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -march=x86-64 -mtune=generic -mno-avx -mno-sse4")
endif()

# *****************************************************************************
# Include cmake tools
# *****************************************************************************
include(MessageColors)
include(LoggingHelper)

# *****************************************************************************
# Options
# *****************************************************************************
option(OPTIONS_ENABLE_CCACHE "Enable ccache" OFF)
option(OPTIONS_ENABLE_SCCACHE "Use sccache to speed up compilation process" OFF)
option(OPTIONS_ENABLE_IPO "Check and Enable interprocedural optimization (IPO/LTO)" ON)
option(FEATURE_METRICS "Enable metrics feature" OFF)

# *****************************************************************************
# Options Code
# *****************************************************************************

if(FEATURE_METRICS)
    log_option_enabled("metrics")
else ()
    log_option_disabled("metrics")
endif ()

# === Compiler cache (sccache preferred when requested; ccache fallback) ===
set(_IDLEOT_COMPILER_LAUNCHER "")
if(OPTIONS_ENABLE_SCCACHE)
    find_program(SCCACHE_PATH sccache)
    if(SCCACHE_PATH)
        set(_IDLEOT_COMPILER_LAUNCHER "${SCCACHE_PATH}")
        log_option_enabled("sccache")
    else()
        log_option_disabled("sccache")
    endif()
endif()
if(NOT _IDLEOT_COMPILER_LAUNCHER AND OPTIONS_ENABLE_CCACHE)
    find_program(CCACHE ccache)
    if(CCACHE)
        set(_IDLEOT_COMPILER_LAUNCHER "${CCACHE}")
        log_option_enabled("ccache")
    else()
        log_option_disabled("ccache")
    endif()
endif()
# macOS presets historically enable sccache; fall back to Homebrew ccache when sccache is absent.
if(NOT _IDLEOT_COMPILER_LAUNCHER AND OPTIONS_ENABLE_SCCACHE)
    find_program(CCACHE ccache)
    if(CCACHE)
        message(STATUS "sccache not found; falling back to ccache (${CCACHE})")
        set(_IDLEOT_COMPILER_LAUNCHER "${CCACHE}")
    endif()
endif()
if(_IDLEOT_COMPILER_LAUNCHER AND COMMAND idleot_pin_compiler_launcher)
    idleot_pin_compiler_launcher(_IDLEOT_COMPILER_LAUNCHER)
endif()
if(_IDLEOT_COMPILER_LAUNCHER)
    set(CMAKE_C_COMPILER_LAUNCHER "${_IDLEOT_COMPILER_LAUNCHER}")
    set(CMAKE_CXX_COMPILER_LAUNCHER "${_IDLEOT_COMPILER_LAUNCHER}")
endif()

option(BUILD_TESTS "Build tests" OFF) # By default, tests will not be built
option(RUN_TESTS_AFTER_BUILD "Run tests when building" OFF) # By default, tests will only run if requested

# IdleOT map tooling (occupancy + map-query) lives in packages/map-tools.
set(IDLEOT_MAP_TOOLS_DIR "" CACHE PATH "Path to packages/map-tools (set by tibiajs Makefile)")

# *****************************************************************************
# Add project
# *****************************************************************************
add_subdirectory(src)

if(IDLEOT_MAP_TOOLS_DIR)
	add_subdirectory(${IDLEOT_MAP_TOOLS_DIR} ${CMAKE_BINARY_DIR}/idleot-map-tools)
endif()

if(BUILD_TESTS OR PACKAGE_TESTS)
    add_subdirectory(tests)
endif()
