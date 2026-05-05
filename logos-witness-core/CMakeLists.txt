cmake_minimum_required(VERSION 3.14)
project(LogosWitnessCorePlugin LANGUAGES CXX)

# Provided by logos-module-builder via $LOGOS_MODULE_BUILDER_ROOT in nix builds.
if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cmake/LogosModule.cmake")
    include(cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found")
endif()

# Discover protobuf via pkg-config — the nixpkgs `protobuf` package's
# CMake config exports are unreliable across versions but its pkg-config
# files are stable. Drive `protoc` directly so the generation step does
# not depend on the FindProtobuf module either.
find_package(PkgConfig REQUIRED)
pkg_check_modules(PROTOBUF REQUIRED IMPORTED_TARGET protobuf)
find_program(PROTOC_EXECUTABLE NAMES protoc REQUIRED)

set(PROTO_GEN_DIR ${CMAKE_CURRENT_BINARY_DIR})
set(PROTO_SRC ${PROTO_GEN_DIR}/reference.pb.cc)
set(PROTO_HDR ${PROTO_GEN_DIR}/reference.pb.h)

add_custom_command(
    OUTPUT ${PROTO_SRC} ${PROTO_HDR}
    COMMAND ${PROTOC_EXECUTABLE}
            --cpp_out=${PROTO_GEN_DIR}
            -I${CMAKE_CURRENT_SOURCE_DIR}/proto
            ${CMAKE_CURRENT_SOURCE_DIR}/proto/reference.proto
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/proto/reference.proto
    COMMENT "Generating protobuf bindings for reference.proto"
    VERBATIM
)
set_source_files_properties(${PROTO_SRC} ${PROTO_HDR} PROPERTIES GENERATED TRUE)

logos_module(
    NAME logos_witness_core
    SOURCES
        src/logos_witness_core_interface.h
        src/logos_witness_core_plugin.h
        src/logos_witness_core_plugin.cpp
        ${PROTO_SRC}
        ${PROTO_HDR}
    INCLUDE_DIRS
        ${PROTO_GEN_DIR}
    LINK_LIBRARIES
        PkgConfig::PROTOBUF
)

# -----------------------------------------------------------------------------
# Tests
#
# The lgx packaging path (nix build .#lgx) does not run ctest. Tests are run
# from a `nix develop` shell with: cmake -B build -GNinja && cmake --build
# build && ctest --test-dir build --output-on-failure
# -----------------------------------------------------------------------------
include(CTest)
if(BUILD_TESTING)
    add_executable(test_reference_codec
        tests/test_reference_codec.cpp
        ${PROTO_SRC}
        ${PROTO_HDR}
    )
    target_include_directories(test_reference_codec PRIVATE ${PROTO_GEN_DIR})
    target_link_libraries(test_reference_codec PRIVATE PkgConfig::PROTOBUF)
    add_test(NAME reference_codec_roundtrip COMMAND test_reference_codec)
endif()
