cmake_minimum_required(VERSION 3.14)
project(ollama_embed VERSION 1.0.0 LANGUAGES C CXX)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# MySQL include directory
#
# Set MYSQL_INCLUDE_DIR to the directory that contains mysql.h.
# Common locations:
#   /usr/include/mysql                  (Linux packages)
#   /usr/local/mysql/include            (tarball install)
#   C:/Program Files/MySQL/.../include  (Windows)
#
# Example:
#   cmake -DMYSQL_INCLUDE_DIR=/usr/include/mysql ..
# ---------------------------------------------------------------------------
if(NOT DEFINED MYSQL_INCLUDE_DIR)
    # Try common default locations automatically
    find_path(MYSQL_INCLUDE_DIR
        NAMES mysql.h
        PATHS
            /usr/include/mysql
            /usr/local/include/mysql
            /usr/local/mysql/include
            /opt/mysql/include
            /opt/homebrew/include/mysql
        DOC "Path to the MySQL include directory (containing mysql.h)"
    )
endif()

if(NOT MYSQL_INCLUDE_DIR)
    message(FATAL_ERROR
        "MySQL include directory not found.\n"
        "Pass -DMYSQL_INCLUDE_DIR=<path> to cmake.\n"
        "Example: cmake -DMYSQL_INCLUDE_DIR=/usr/include/mysql .."
    )
endif()

message(STATUS "MySQL include dir: ${MYSQL_INCLUDE_DIR}")

# ---------------------------------------------------------------------------
# libcurl
# ---------------------------------------------------------------------------
find_package(CURL REQUIRED)

# ---------------------------------------------------------------------------
# Shared library target
# ---------------------------------------------------------------------------
add_library(ollama_embed SHARED
    src/ollama_embed.cc
    include/cJSON.c          # bundled cJSON implementation (C source)
)

target_include_directories(ollama_embed
    PRIVATE
        ${MYSQL_INCLUDE_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${CURL_INCLUDE_DIRS}
)

target_link_libraries(ollama_embed
    PRIVATE
        ${CURL_LIBRARIES}
)

target_compile_options(ollama_embed PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:/W4>
    $<$<OR:$<CXX_COMPILER_ID:GNU>,$<CXX_COMPILER_ID:Clang>,$<CXX_COMPILER_ID:AppleClang>>:-Wall;-Wextra>
)

# MySQL UDFs must not have a "lib" prefix
set_target_properties(ollama_embed PROPERTIES
    PREFIX ""
    OUTPUT_NAME "ollama_embed"
)

# Strip the SONAME so MySQL can load the .so by the bare file name
set_target_properties(ollama_embed PROPERTIES
    NO_SONAME ON
)

# ---------------------------------------------------------------------------
# Optional: install target — copies the .so to the MySQL plugin directory.
# Override with: cmake -DMYSQL_PLUGIN_DIR=/usr/lib/mysql/plugin ..
# ---------------------------------------------------------------------------
if(NOT DEFINED MYSQL_PLUGIN_DIR)
    set(MYSQL_PLUGIN_DIR "/usr/lib/mysql/plugin" CACHE PATH
        "MySQL plugin directory where ollama_embed.so will be installed")
endif()

install(TARGETS ollama_embed
    LIBRARY DESTINATION ${MYSQL_PLUGIN_DIR}
)
