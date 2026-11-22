cmake_minimum_required(VERSION 3.22.1)
project(wikidict_egyptian LANGUAGES CXX)
add_library(wikidict_egyptian SHARED
    "${CMAKE_CURRENT_LIST_DIR}/../../../../../renderer/src/shaping/android/egyptian_shape.cpp"
    vendor/harfbuzz/src/harfbuzz.cc)
set_property(GLOBAL APPEND PROPERTY JOB_POOLS wikidict_egyptian_compile=2)
set_property(TARGET wikidict_egyptian PROPERTY JOB_POOL_COMPILE wikidict_egyptian_compile)
target_include_directories(wikidict_egyptian PRIVATE vendor/harfbuzz/src)
set_target_properties(wikidict_egyptian PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED YES CXX_EXTENSIONS NO)
# Android Canvas draws the shaped glyphs; HarfBuzz only supplies their layout.
target_compile_definitions(wikidict_egyptian PRIVATE HB_NO_DRAW)
target_compile_options(wikidict_egyptian PRIVATE -fvisibility=hidden -fvisibility-inlines-hidden -fno-exceptions -fno-rtti)
target_link_options(wikidict_egyptian PRIVATE
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/exports.map"
    "-Wl,--no-undefined" "-Wl,-z,max-page-size=16384")
set_property(TARGET wikidict_egyptian APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/exports.map")
