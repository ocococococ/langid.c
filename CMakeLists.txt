cmake_minimum_required(VERSION 3.16)

project(langid_c LANGUAGES C)

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
option(LANGID_REGENERATE_MODEL
  "Regenerate model.c/model.h from LANGID_MODEL with Python 3 (needs the langid and numpy packages)"
  OFF)
set(LANGID_MODEL "${CMAKE_CURRENT_SOURCE_DIR}/ldpy.model" CACHE FILEPATH
  "langid.py model to compile into the library when LANGID_REGENERATE_MODEL=ON")
option(LANGID_BUILD_PYTHON "Build the _langid Python 3 extension module" OFF)
option(LANGID_DEBUG "Enable liblangid debug output (-DDEBUG)" OFF)
option(LANGID_STATIC_PROTOBUF_C "Link protobuf-c statically (libprotobuf-c.a)" ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE MinSizeRel CACHE STRING "Build type" FORCE)
endif()

# ---------------------------------------------------------------------------
# Dependencies: protobuf-c
# ---------------------------------------------------------------------------
find_package(PkgConfig QUIET)
if(PKG_CONFIG_FOUND)
  pkg_check_modules(PROTOBUF_C QUIET IMPORTED_TARGET libprotobuf-c)
endif()

if(LANGID_STATIC_PROTOBUF_C)
  # Look only for the static archive, using pkg-config's paths as hints.
  find_path(PROTOBUF_C_INCLUDE_DIR protobuf-c/protobuf-c.h
    HINTS ${PROTOBUF_C_INCLUDE_DIRS})
  find_library(PROTOBUF_C_STATIC_LIBRARY
    NAMES ${CMAKE_STATIC_LIBRARY_PREFIX}protobuf-c${CMAKE_STATIC_LIBRARY_SUFFIX}
    HINTS ${PROTOBUF_C_LIBRARY_DIRS})
  if(NOT PROTOBUF_C_INCLUDE_DIR OR NOT PROTOBUF_C_STATIC_LIBRARY)
    message(FATAL_ERROR "Static protobuf-c library not found. Install it, or configure "
                        "with -DLANGID_STATIC_PROTOBUF_C=OFF to link it dynamically.")
  endif()
  add_library(langid_protobuf_c STATIC IMPORTED)
  set_target_properties(langid_protobuf_c PROPERTIES
    IMPORTED_LOCATION "${PROTOBUF_C_STATIC_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${PROTOBUF_C_INCLUDE_DIR}")
  set(LANGID_PROTOBUF_C_TARGET langid_protobuf_c)
  message(STATUS "Linking protobuf-c statically: ${PROTOBUF_C_STATIC_LIBRARY}")
elseif(PROTOBUF_C_FOUND)
  set(LANGID_PROTOBUF_C_TARGET PkgConfig::PROTOBUF_C)
else()
  find_path(PROTOBUF_C_INCLUDE_DIR protobuf-c/protobuf-c.h)
  find_library(PROTOBUF_C_LIBRARY NAMES protobuf-c)
  if(NOT PROTOBUF_C_INCLUDE_DIR OR NOT PROTOBUF_C_LIBRARY)
    message(FATAL_ERROR "protobuf-c not found. Install it (e.g. `brew install protobuf-c` "
                        "or `apt install libprotobuf-c-dev protobuf-c-compiler`).")
  endif()
  add_library(langid_protobuf_c UNKNOWN IMPORTED)
  set_target_properties(langid_protobuf_c PROPERTIES
    IMPORTED_LOCATION "${PROTOBUF_C_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${PROTOBUF_C_INCLUDE_DIR}")
  set(LANGID_PROTOBUF_C_TARGET langid_protobuf_c)
endif()

# Generate langid.pb-c.{c,h}. Prefer `protoc` + the protoc-gen-c plugin
# (protoc-c is deprecated in recent protobuf-c releases), fall back to protoc-c.
find_program(PROTOC_EXECUTABLE protoc)
find_program(PROTOC_GEN_C_EXECUTABLE protoc-gen-c)
find_program(PROTOC_C_EXECUTABLE protoc-c)

set(LANGID_PROTO "${CMAKE_CURRENT_SOURCE_DIR}/langid.proto")
set(LANGID_PB_C "${CMAKE_CURRENT_BINARY_DIR}/langid.pb-c.c")
set(LANGID_PB_H "${CMAKE_CURRENT_BINARY_DIR}/langid.pb-c.h")

if(PROTOC_EXECUTABLE AND PROTOC_GEN_C_EXECUTABLE)
  set(LANGID_PROTOC_CMD "${PROTOC_EXECUTABLE}"
      "--plugin=protoc-gen-c=${PROTOC_GEN_C_EXECUTABLE}")
elseif(PROTOC_C_EXECUTABLE)
  set(LANGID_PROTOC_CMD "${PROTOC_C_EXECUTABLE}")
else()
  message(FATAL_ERROR "Neither protoc + protoc-gen-c nor protoc-c was found.")
endif()

add_custom_command(
  OUTPUT "${LANGID_PB_C}" "${LANGID_PB_H}"
  COMMAND ${LANGID_PROTOC_CMD}
          "--proto_path=${CMAKE_CURRENT_SOURCE_DIR}"
          "--c_out=${CMAKE_CURRENT_BINARY_DIR}"
          "${LANGID_PROTO}"
  DEPENDS "${LANGID_PROTO}"
  COMMENT "Generating langid.pb-c.c/h from langid.proto"
  VERBATIM)

# ---------------------------------------------------------------------------
# Built-in model (model.c / model.h)
# ---------------------------------------------------------------------------
if(LANGID_REGENERATE_MODEL)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  set(LANGID_MODEL_DIR "${CMAKE_CURRENT_BINARY_DIR}/model")
  set(LANGID_MODEL_C "${LANGID_MODEL_DIR}/model.c")
  set(LANGID_MODEL_H "${LANGID_MODEL_DIR}/model.h")
  set(LDPY2LDC "${CMAKE_CURRENT_SOURCE_DIR}/ldpy2ldc.py")
  file(MAKE_DIRECTORY "${LANGID_MODEL_DIR}")
  add_custom_command(
    OUTPUT "${LANGID_MODEL_H}"
    COMMAND Python3::Interpreter "${LDPY2LDC}" --header "${LANGID_MODEL}" -o "${LANGID_MODEL_H}"
    DEPENDS "${LANGID_MODEL}" "${LDPY2LDC}"
    COMMENT "Generating model.h from ${LANGID_MODEL}"
    VERBATIM)
  add_custom_command(
    OUTPUT "${LANGID_MODEL_C}"
    COMMAND Python3::Interpreter "${LDPY2LDC}" "${LANGID_MODEL}" -o "${LANGID_MODEL_C}"
    DEPENDS "${LANGID_MODEL}" "${LDPY2LDC}"
    COMMENT "Generating model.c from ${LANGID_MODEL}"
    VERBATIM)
  # liblangid.c does #include "model.h", which compilers resolve relative to
  # the including file first. Compile a copy that sits next to the generated
  # header so the in-tree model.h cannot shadow it.
  configure_file(liblangid.c "${LANGID_MODEL_DIR}/liblangid.c" COPYONLY)
  set(LANGID_LIB_SRC "${LANGID_MODEL_DIR}/liblangid.c")
else()
  set(LANGID_LIB_SRC liblangid.c)
  set(LANGID_MODEL_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
  set(LANGID_MODEL_C "${CMAKE_CURRENT_SOURCE_DIR}/model.c")
  set(LANGID_MODEL_H "${CMAKE_CURRENT_SOURCE_DIR}/model.h")
  if(NOT EXISTS "${LANGID_MODEL_C}" OR NOT EXISTS "${LANGID_MODEL_H}")
    message(FATAL_ERROR "model.c/model.h are missing; configure with -DLANGID_REGENERATE_MODEL=ON")
  endif()
endif()

# ---------------------------------------------------------------------------
# liblangid
# ---------------------------------------------------------------------------
add_library(langid_lib STATIC
  "${LANGID_LIB_SRC}"
  sparseset.c
  "${LANGID_MODEL_C}"
  "${LANGID_MODEL_H}"
  "${LANGID_PB_C}"
  "${LANGID_PB_H}")
set_target_properties(langid_lib PROPERTIES
  OUTPUT_NAME langid
  POSITION_INDEPENDENT_CODE ON)
target_include_directories(langid_lib
  PUBLIC  "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}"
  PRIVATE "${LANGID_MODEL_DIR}")
target_link_libraries(langid_lib PUBLIC ${LANGID_PROTOBUF_C_TARGET})
if(LANGID_DEBUG)
  target_compile_definitions(langid_lib PUBLIC DEBUG)
endif()
if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
  target_compile_options(langid_lib PRIVATE -Wall)
endif()

# ---------------------------------------------------------------------------
# langid command-line tool
# ---------------------------------------------------------------------------
add_executable(langid langid.c)
target_link_libraries(langid PRIVATE langid_lib)
if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
  target_compile_options(langid PRIVATE -Wall)
endif()

include(GNUInstallDirs)
install(TARGETS langid RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

# ---------------------------------------------------------------------------
# Optional Python 3 extension module
# ---------------------------------------------------------------------------
if(LANGID_BUILD_PYTHON)
  find_package(Python3 REQUIRED COMPONENTS Interpreter Development.Module)
  Python3_add_library(_langid MODULE WITH_SOABI _langid.c)
  target_link_libraries(_langid PRIVATE langid_lib)
endif()
