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
pkg_check_modules(LIBJPEG  REQUIRED IMPORTED_TARGET libjpeg)
find_program(PROTOC_EXECUTABLE NAMES protoc REQUIRED)

# Run logos-cpp-generator in dev-shell builds (cmake outside nix). The nix
# build of `.#lgx` populates generated_code/ in its preConfigure phase;
# without this step, dev-shell ctest can't compile the plugin because
# storage_module_api.h and logos_sdk.h are missing.
set(LOGOS_GENERATED_DIR ${CMAKE_CURRENT_SOURCE_DIR}/generated_code)
if(NOT EXISTS ${LOGOS_GENERATED_DIR}/include/logos_sdk.h)
    find_program(LOGOS_CPP_GENERATOR logos-cpp-generator
        HINTS $ENV{LOGOS_CPP_SDK_ROOT}/bin
        REQUIRED)
    file(MAKE_DIRECTORY ${LOGOS_GENERATED_DIR})
    execute_process(
        COMMAND ${LOGOS_CPP_GENERATOR}
                --metadata ${CMAKE_CURRENT_SOURCE_DIR}/metadata.json
                --general-only
                --output-dir ${LOGOS_GENERATED_DIR}
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        RESULT_VARIABLE _gen_rc)
    if(NOT _gen_rc EQUAL 0)
        message(FATAL_ERROR "logos-cpp-generator failed (rc=${_gen_rc})")
    endif()
    # Mirror mkModuleLib.nix layout: headers under include/, .cpp files
    # copied into include/ too (LogosModule.cmake's installed-layout
    # branch hunts both .cpp locations).
    file(MAKE_DIRECTORY ${LOGOS_GENERATED_DIR}/include)
    file(GLOB _gen_headers ${LOGOS_GENERATED_DIR}/*.h)
    foreach(h ${_gen_headers})
        get_filename_component(_hn ${h} NAME)
        file(RENAME ${h} ${LOGOS_GENERATED_DIR}/include/${_hn})
    endforeach()
    file(GLOB _gen_sources ${LOGOS_GENERATED_DIR}/*.cpp)
    foreach(c ${_gen_sources})
        get_filename_component(_cn ${c} NAME)
        file(RENAME ${c} ${LOGOS_GENERATED_DIR}/include/${_cn})
    endforeach()
    # Pull in any include files shipped by declared module dependencies
    # (storage_module ships storage_module_api.h/.cpp under
    # packages.<system>.default/include — copy them in). The nix build
    # gets these via moduleInputs; for dev-shell ctest we shell out to
    # `nix build` to discover the same path.
    execute_process(
        COMMAND nix build --no-link --print-out-paths
                github:logos-co/logos-storage-module
        OUTPUT_VARIABLE _sm_path
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _sm_rc)
    if(_sm_rc EQUAL 0 AND EXISTS "${_sm_path}/include")
        file(GLOB _sm_files "${_sm_path}/include/*")
        file(COPY ${_sm_files} DESTINATION ${LOGOS_GENERATED_DIR}/include)
    else()
        message(WARNING "storage_module include dir not resolved; plugin link may fail")
    endif()
endif()

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
        lib/geohash.h
        lib/in_memory_store.h
        lib/in_memory_store.cpp
        lib/exif_strip.h
        lib/exif_strip.cpp
        lib/storage_client.h
        lib/storage_client.cpp
        ${PROTO_SRC}
        ${PROTO_HDR}
    INCLUDE_DIRS
        ${PROTO_GEN_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/lib
    LINK_LIBRARIES
        PkgConfig::PROTOBUF
        PkgConfig::LIBJPEG
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

    add_executable(test_geohash tests/test_geohash.cpp)
    target_include_directories(test_geohash PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/lib)
    add_test(NAME geohash_decode COMMAND test_geohash)

    # Strip-pipeline unit tests. Decoded-pixel SHA-256 is computed via
    # libjpeg + a vendored SHA-256 (tests/sha256.h); the fixtures under
    # tests/fixtures/ are regenerated by tests/fixtures/generate.sh.
    add_executable(test_exif_strip
        tests/test_exif_strip.cpp
        lib/exif_strip.cpp
    )
    target_include_directories(test_exif_strip PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/lib
        ${CMAKE_CURRENT_SOURCE_DIR}/tests
    )
    target_link_libraries(test_exif_strip PRIVATE PkgConfig::LIBJPEG)
    target_compile_definitions(test_exif_strip PRIVATE
        FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
        STRIPPED_OUTPUT_DIR="${CMAKE_CURRENT_BINARY_DIR}/stripped"
    )
    file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/stripped)
    add_test(NAME exif_strip COMMAND test_exif_strip)

    # SPEC §7.1 / Phase 4.2 — residual-metadata gate. Independent
    # verification (exiftool over the strip outputs) layered on top of
    # the marker-scan inside test_exif_strip; this is what catches
    # implementation bugs where a marker is preserved by mistake or
    # libjpeg-turbo writes APPn metadata we didn't ask for.
    find_program(EXIFTOOL_EXECUTABLE NAMES exiftool)
    if(EXIFTOOL_EXECUTABLE)
        add_test(NAME exiftool_residual_gate
            COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/exiftool_gate.sh
                    ${CMAKE_CURRENT_BINARY_DIR}/stripped
        )
        # The gate consumes the outputs that exif_strip writes; ctest's
        # DEPENDS only sets ordering (no implicit fail-fast). Pair with
        # REQUIRED_FILES so a missing dir surfaces as a clean error
        # before exiftool sees nothing.
        set_tests_properties(exiftool_residual_gate PROPERTIES
            DEPENDS exif_strip
            REQUIRED_FILES "${CMAKE_CURRENT_BINARY_DIR}/stripped"
        )

        # Negative self-test: point the gate at the *unstripped* fixture
        # directory (every fixture there is built to carry identifying
        # metadata, see tests/fixtures/generate.sh). The gate must report
        # residue and exit nonzero. Guards against silent regressions in
        # the filter logic — e.g. an earlier draft of the script used
        # `-Group:all=` (the write syntax, which clobbers files and emits
        # no output) instead of `--Group:all` (the read filter); without
        # this self-test that bug would have gone unnoticed indefinitely.
        add_test(NAME exiftool_residual_gate_negative
            COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/exiftool_gate.sh
                    ${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures
        )
        set_tests_properties(exiftool_residual_gate_negative PROPERTIES
            WILL_FAIL TRUE
        )
    else()
        message(WARNING
            "exiftool not found — skipping Phase 4.2 residual-metadata gate. "
            "Install exiftool (already in metadata.json nix.packages.build) "
            "and re-run cmake to enable.")
    endif()
endif()
