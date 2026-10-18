cmake_minimum_required(VERSION 3.21)
project(DictQt VERSION 0.1.0 LANGUAGES CXX)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Widgets Concurrent Network Multimedia)
qt_standard_project_setup()

add_executable(dict-qt
    main.cpp
    DictApi.cpp
    LearningStore.cpp
    MainWindow.cpp
    LibraryDialog.cpp
    LibraryStore.cpp
    MediaPanel.cpp
)
qt_add_resources(dict-qt reader_font PREFIX "/fonts"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/../web"
    FILES "${CMAKE_CURRENT_SOURCE_DIR}/../web/reader.ttf")

qt_add_resources(dict-qt egyptian_font PREFIX "/fonts"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/fonts"
    FILES "${CMAKE_CURRENT_SOURCE_DIR}/fonts/NewGardinerOmni2d4.ttf")

target_compile_features(dict-qt PRIVATE cxx_std_20)
target_compile_options(dict-qt PRIVATE -Wall -Wextra -Wpedantic)
target_include_directories(dict-qt PRIVATE "${WIKIDICT_CORE}/src/ffi")

find_library(DICT_FFI_LIBRARY
    NAMES dictffi
    PATHS "${WIKIDICT_CORE}/zig-out/lib"
    NO_DEFAULT_PATH
    REQUIRED
)

target_link_libraries(dict-qt PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Concurrent Qt6::Network Qt6::Multimedia "${DICT_FFI_LIBRARY}")
set_target_properties(dict-qt PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    BUILD_RPATH "${WIKIDICT_CORE}/zig-out/lib"
    INSTALL_RPATH "$ORIGIN/../lib"
)

if(BUILD_TESTING)
    find_package(Qt6 6.5 REQUIRED COMPONENTS Test)
    add_executable(dict-qt-tests ../tests/MainWindowTest.cpp DictApi.cpp LearningStore.cpp MainWindow.cpp LibraryDialog.cpp LibraryStore.cpp MediaPanel.cpp)
    qt_add_resources(dict-qt-tests test_egyptian_font PREFIX "/fonts"
        BASE "${CMAKE_CURRENT_SOURCE_DIR}/fonts"
        FILES "${CMAKE_CURRENT_SOURCE_DIR}/fonts/NewGardinerOmni2d4.ttf")

    target_compile_features(dict-qt-tests PRIVATE cxx_std_20)
    target_compile_options(dict-qt-tests PRIVATE -Wall -Wextra -Wpedantic)
    target_include_directories(dict-qt-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${WIKIDICT_CORE}/src/ffi")
    target_link_libraries(dict-qt-tests PRIVATE Qt6::Widgets Qt6::Test Qt6::Concurrent Qt6::Network Qt6::Multimedia "${DICT_FFI_LIBRARY}")
    qt_add_resources(dict-qt-tests test_reader_font PREFIX "/fonts"
        BASE "${CMAKE_CURRENT_SOURCE_DIR}/../web"
        FILES "${CMAKE_CURRENT_SOURCE_DIR}/../web/reader.ttf")
    add_test(NAME native-reader-ux COMMAND dict-qt-tests)
    set_tests_properties(native-reader-ux PROPERTIES
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;DICT_TEST_ROOT=${CMAKE_SOURCE_DIR}/tests/fixtures")
    add_executable(dict-fake-voice ../tests/FakeVoice.cpp)
    target_compile_features(dict-fake-voice PRIVATE cxx_std_20)
    set_target_properties(dict-fake-voice PROPERTIES AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
    add_executable(dict-media-tests ../tests/MediaPanelTest.cpp MediaPanel.cpp)
    add_dependencies(dict-media-tests dict-fake-voice)
    target_compile_definitions(dict-media-tests PRIVATE DICT_FAKE_VOICE_PATH="$<TARGET_FILE:dict-fake-voice>")
    target_compile_features(dict-media-tests PRIVATE cxx_std_20)
    target_include_directories(dict-media-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(dict-media-tests PRIVATE Qt6::Widgets Qt6::Network Qt6::Multimedia Qt6::Test)
    add_test(NAME native-media-ux COMMAND dict-media-tests)
    set_tests_properties(native-media-ux PROPERTIES WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}" ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    add_executable(dict-library-tests ../tests/LibraryStoreTests.cpp LibraryStore.cpp)
    target_compile_features(dict-library-tests PRIVATE cxx_std_20)
    target_include_directories(dict-library-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(dict-library-tests PRIVATE Qt6::Core)
    add_test(NAME native-library-storage COMMAND dict-library-tests)
    set_tests_properties(native-library-storage PROPERTIES WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}")
    add_executable(dict-library-ui-tests ../tests/LibraryDialogTests.cpp LibraryDialog.cpp LibraryStore.cpp)
    target_compile_features(dict-library-ui-tests PRIVATE cxx_std_20)
    target_include_directories(dict-library-ui-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(dict-library-ui-tests PRIVATE Qt6::Widgets Qt6::Network Qt6::Test)
    add_test(NAME native-library-ux COMMAND dict-library-ui-tests
        "${CMAKE_SOURCE_DIR}/tests/fixtures/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb")
    set_tests_properties(native-library-ux PROPERTIES WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}" ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    foreach(native_test IN ITEMS native-reader-ux native-media-ux native-library-storage native-library-ux)
        set_property(TEST ${native_test} APPEND PROPERTY ENVIRONMENT
            "XDG_CONFIG_HOME=${CMAKE_SOURCE_DIR}/.tmp/ctest/${native_test}/config"
            "XDG_CACHE_HOME=${CMAKE_SOURCE_DIR}/.tmp/ctest/${native_test}/cache"
            "XDG_DATA_HOME=${CMAKE_SOURCE_DIR}/.tmp/ctest/${native_test}/data")
    endforeach()
endif()
