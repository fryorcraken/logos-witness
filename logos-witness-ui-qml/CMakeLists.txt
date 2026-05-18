cmake_minimum_required(VERSION 3.14)
project(LogosWitnessUiQmlPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

logos_module(
    NAME logos_witness_ui_qml
    REP_FILE src/logos_witness_ui_qml.rep
    SOURCES
        src/logos_witness_ui_qml_interface.h
        src/logos_witness_ui_qml_plugin.h
        src/logos_witness_ui_qml_plugin.cpp
)
