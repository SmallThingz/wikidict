cmake_minimum_required(VERSION 3.21)
project(DictQt VERSION 0.1.0 LANGUAGES CXX)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Widgets)
qt_standard_project_setup()

add_executable(dict-qt
    main.cpp
    DictApi.cpp
    LearningStore.cpp
    MainWindow.cpp
)

target_compile_features(dict-qt PRIVATE cxx_std_20)
target_compile_options(dict-qt PRIVATE -Wall -Wextra -Wpedantic)
target_include_directories(dict-qt PRIVATE ../ffi)

find_library(DICT_FFI_LIBRARY
    NAMES dictffi
    PATHS "${CMAKE_SOURCE_DIR}/../../zig-out/lib"
    NO_DEFAULT_PATH
    REQUIRED
)

target_link_libraries(dict-qt PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets "${DICT_FFI_LIBRARY}")
set_target_properties(dict-qt PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/../../zig-out/bin"
    BUILD_RPATH "${CMAKE_SOURCE_DIR}/../../zig-out/lib"
    INSTALL_RPATH "$ORIGIN/../lib"
)
