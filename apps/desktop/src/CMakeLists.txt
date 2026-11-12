cmake_minimum_required(VERSION 3.21)
project(DictQt VERSION 0.1.0 LANGUAGES CXX)

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui Widgets Concurrent Network Multimedia Svg)
qt_standard_project_setup()

# Compile product code once under the shipped GUI's compilation contract.
# Tests link these objects; the fake-voice MediaPanel variant stays separate.
add_library(wikidict-product STATIC
    DictApi.cpp
    LearningStore.cpp
    MainWindow.cpp
    LibraryDialog.cpp
    LibraryStore.cpp
    MediaPanel.cpp
    InlineVectorImages.hpp
)
add_library(wikidict-gui SHARED main.cpp)
qt_add_resources(wikidict-gui reader_font PREFIX "/fonts"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/../web"
    FILES "${CMAKE_CURRENT_SOURCE_DIR}/../web/reader.ttf")

qt_add_resources(wikidict-gui egyptian_font PREFIX "/fonts"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/fonts"
    FILES "${CMAKE_CURRENT_SOURCE_DIR}/fonts/NewGardinerOmni2d4.ttf")

target_compile_features(wikidict-gui PRIVATE cxx_std_20)
target_compile_options(wikidict-gui PRIVATE -Wall -Wextra -Wpedantic)
target_include_directories(wikidict-gui PRIVATE "${WIKIDICT_CORE}/src/ffi")

find_library(DICT_FFI_LIBRARY
    NAMES dictffi
    PATHS "${WIKIDICT_CORE}/zig-out/lib"
    NO_DEFAULT_PATH
    REQUIRED
)

target_compile_features(wikidict-product PRIVATE cxx_std_20)
target_compile_options(wikidict-product PRIVATE -Wall -Wextra -Wpedantic)
target_compile_definitions(wikidict-product PRIVATE wikidict_gui_EXPORTS)
target_include_directories(wikidict-product PRIVATE "${WIKIDICT_CORE}/src/ffi")
set_target_properties(wikidict-product PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
)
# PRIVATE static-library dependencies remain link requirements without adding
# their compile definitions to the existing test-driver translation units.
target_link_libraries(wikidict-product PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Concurrent Qt6::Network Qt6::Multimedia Qt6::Svg "${DICT_FFI_LIBRARY}")

target_link_libraries(wikidict-gui PRIVATE wikidict-product Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Concurrent Qt6::Network Qt6::Multimedia Qt6::Svg "${DICT_FFI_LIBRARY}")
get_filename_component(dict_ffi_directory "${DICT_FFI_LIBRARY}" DIRECTORY)
if(APPLE)
    set(gui_install_rpath "@loader_path")
else()
    set(gui_install_rpath "$ORIGIN")
endif()
set_target_properties(wikidict-gui PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    BUILD_RPATH "${dict_ffi_directory}"
    INSTALL_RPATH "${gui_install_rpath}"
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
)

set(WIKIDICT_EXECUTABLE "${WIKIDICT_CORE}/zig-out/bin/wikidict" CACHE FILEPATH "Unified wikidict executable built by the core cli target")
include("${CMAKE_CURRENT_SOURCE_DIR}/InstallCore.cmake")
wikidict_select_install_core("${WIKIDICT_EXECUTABLE}" "${DICT_FFI_LIBRARY}"
    "${WIKIDICT_CORE}/src/ffi/dict.h")
install(TARGETS wikidict-gui LIBRARY DESTINATION lib RUNTIME DESTINATION bin)
install(FILES "${wikidict_install_ffi}" DESTINATION lib)
install(PROGRAMS "${wikidict_install_executable}" DESTINATION bin RENAME wikidict)
if(NOT wikidict_install_header STREQUAL "")
    install(FILES "${wikidict_install_header}" DESTINATION include/dict)
endif()
install(FILES org.smallthingz.wikidict.desktop DESTINATION share/applications)
install(FILES "${WIKIDICT_CORE}/docs/assets/language-globe.svg"
    DESTINATION share/icons/hicolor/scalable/apps RENAME org.smallthingz.wikidict.svg)
install(CODE [[
    foreach(alias IN ITEMS wikidict-gio dict)
        file(CREATE_LINK "wikidict" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/bin/${alias}" SYMBOLIC)
    endforeach()
]])

include("${CMAKE_CURRENT_SOURCE_DIR}/PrivateQtRuntime.cmake")

if(BUILD_TESTING)
    add_test(NAME native-install-core-selection
        COMMAND "${CMAKE_COMMAND}"
            "-DINSTALL_CORE_MODULE=${CMAKE_CURRENT_SOURCE_DIR}/InstallCore.cmake"
            "-DTEST_ROOT=${CMAKE_BINARY_DIR}/.tmp/install-core-selection"
            -P "${CMAKE_SOURCE_DIR}/tests/install_core_selection_check.cmake")
    set_tests_properties(native-install-core-selection PROPERTIES TIMEOUT 120)
    find_package(Qt6 6.6 REQUIRED COMPONENTS Test GuiPrivate)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        add_library(wikidict-test-settings SHARED ../tests/UnifiedSettingsBootstrap.cpp)
        target_compile_features(wikidict-test-settings PRIVATE cxx_std_20)
        target_link_libraries(wikidict-test-settings PRIVATE Qt6::Core)
        set_target_properties(wikidict-test-settings PROPERTIES AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
        if(WIKIDICT_BUNDLE_QT_RUNTIME)
            # Test support is installed only into the smoke test's owned stage.
            # Its Core dependency must not load a build-tree Qt before the GUI.
            set_target_properties(wikidict-test-settings PROPERTIES INSTALL_RPATH "$ORIGIN")
            install(TARGETS wikidict-test-settings LIBRARY DESTINATION lib
                COMPONENT wikidict-test-support EXCLUDE_FROM_ALL)
        endif()
        find_package(Python3 REQUIRED COMPONENTS Interpreter)
        add_test(NAME native-unified-entry
            COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/tests/unified_entry_check.py"
                --config "$<CONFIG>"
                ${WIKIDICT_UNIFIED_RUNTIME_ARGUMENT}
                --install-from "${CMAKE_BINARY_DIR}"
                "$<TARGET_FILE:wikidict-test-settings>"
                "${CMAKE_SOURCE_DIR}/tests/fixtures"
                "${CMAKE_BINARY_DIR}/.tmp")
        set_tests_properties(native-unified-entry PROPERTIES
            WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" TIMEOUT 300)
    endif()
    add_executable(dict-qt-tests ../tests/MainWindowTest.cpp)
    if(CMAKE_CXX_COMPILER_ID MATCHES "^(GNU|Clang|AppleClang)$" AND NOT CMAKE_GENERATOR STREQUAL "Xcode")
        # Avoid optimizing the large test driver; all product translation units
        # and the shipped application retain their normal Release options.
        # Xcode does not support configuration-dependent per-source options.
        set_property(SOURCE ../tests/MainWindowTest.cpp APPEND PROPERTY
            COMPILE_OPTIONS "$<$<CONFIG:Release>:-O0>")
    endif()
    qt_add_resources(dict-qt-tests test_egyptian_font PREFIX "/fonts"
        BASE "${CMAKE_CURRENT_SOURCE_DIR}/fonts"
        FILES "${CMAKE_CURRENT_SOURCE_DIR}/fonts/NewGardinerOmni2d4.ttf")

    target_compile_features(dict-qt-tests PRIVATE cxx_std_20)
    target_compile_options(dict-qt-tests PRIVATE -Wall -Wextra -Wpedantic)
    target_include_directories(dict-qt-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${WIKIDICT_CORE}/src/ffi")
    target_link_libraries(dict-qt-tests PRIVATE wikidict-product Qt6::Widgets Qt6::GuiPrivate Qt6::Test Qt6::Concurrent Qt6::Network Qt6::Multimedia Qt6::Svg "${DICT_FFI_LIBRARY}")
    qt_add_resources(dict-qt-tests test_reader_font PREFIX "/fonts"
        BASE "${CMAKE_CURRENT_SOURCE_DIR}/../web"
        FILES "${CMAKE_CURRENT_SOURCE_DIR}/../web/reader.ttf")
    add_test(NAME native-reader-ux COMMAND dict-qt-tests)
    set_tests_properties(native-reader-ux PROPERTIES
        WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;DICT_TEST_ROOT=${CMAKE_SOURCE_DIR}/tests/fixtures")
    add_executable(dict-fake-voice ../tests/FakeVoice.cpp)
    target_compile_features(dict-fake-voice PRIVATE cxx_std_20)
    set_target_properties(dict-fake-voice PROPERTIES AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
    add_executable(dict-media-tests ../tests/MediaPanelTest.cpp MediaPanel.cpp)
    add_dependencies(dict-media-tests dict-fake-voice)
    target_compile_definitions(dict-media-tests PRIVATE DICT_FAKE_VOICE_PATH="$<TARGET_FILE:dict-fake-voice>")
    target_compile_features(dict-media-tests PRIVATE cxx_std_20)
    target_include_directories(dict-media-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(dict-media-tests PRIVATE Qt6::Widgets Qt6::Network Qt6::Multimedia Qt6::Svg Qt6::Test)
    add_test(NAME native-media-ux COMMAND dict-media-tests)
    set_tests_properties(native-media-ux PROPERTIES WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    add_executable(dict-library-tests ../tests/LibraryStoreTests.cpp)
    target_compile_features(dict-library-tests PRIVATE cxx_std_20)
    target_include_directories(dict-library-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${WIKIDICT_CORE}/src/ffi")
    target_link_libraries(dict-library-tests PRIVATE wikidict-product Qt6::Core "${DICT_FFI_LIBRARY}")
    add_test(NAME native-library-storage COMMAND dict-library-tests)
    set_tests_properties(native-library-storage PROPERTIES
        WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
        ENVIRONMENT "DICT_TEST_ROOT=${CMAKE_SOURCE_DIR}/tests/fixtures")
    add_executable(dict-library-ui-tests ../tests/LibraryDialogTests.cpp)
    target_compile_features(dict-library-ui-tests PRIVATE cxx_std_20)
    target_include_directories(dict-library-ui-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${WIKIDICT_CORE}/src/ffi")
    target_link_libraries(dict-library-ui-tests PRIVATE wikidict-product Qt6::Widgets Qt6::Network Qt6::Test "${DICT_FFI_LIBRARY}")
    add_test(NAME native-library-ux COMMAND dict-library-ui-tests
        "${CMAKE_SOURCE_DIR}/tests/fixtures/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb")
    set_tests_properties(native-library-ux PROPERTIES WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    add_test(NAME native-library-catalogue-ux COMMAND dict-library-ui-tests
        "${CMAKE_SOURCE_DIR}/tests/fixtures/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb" --pending-catalogue-import)
    set_tests_properties(native-library-catalogue-ux PROPERTIES WORKING_DIRECTORY "${CMAKE_BINARY_DIR}" ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    foreach(native_test IN ITEMS native-reader-ux native-media-ux native-library-storage native-library-ux native-library-catalogue-ux)
        set_property(TEST ${native_test} APPEND PROPERTY ENVIRONMENT
            "XDG_CONFIG_HOME=${CMAKE_BINARY_DIR}/.tmp/ctest/${native_test}/config"
            "XDG_CACHE_HOME=${CMAKE_BINARY_DIR}/.tmp/ctest/${native_test}/cache"
            "XDG_DATA_HOME=${CMAKE_BINARY_DIR}/.tmp/ctest/${native_test}/data")
    endforeach()
endif()
