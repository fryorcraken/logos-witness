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

logos_module(
    NAME logos_witness_core
    SOURCES
        src/logos_witness_core_interface.h
        src/logos_witness_core_plugin.h
        src/logos_witness_core_plugin.cpp
)
