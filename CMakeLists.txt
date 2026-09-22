cmake_minimum_required(VERSION 3.21)
project(WikidictDesktop VERSION 0.3.0 LANGUAGES CXX)
set(WIKIDICT_CORE "${CMAKE_CURRENT_SOURCE_DIR}/../dict" CACHE PATH "wikidict core checkout (built with zig build ffi)")
add_subdirectory(src)
