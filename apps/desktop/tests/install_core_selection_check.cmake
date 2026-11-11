cmake_minimum_required(VERSION 3.21)
if(NOT IS_ABSOLUTE "${INSTALL_CORE_MODULE}" OR NOT EXISTS "${INSTALL_CORE_MODULE}"
        OR NOT IS_ABSOLUTE "${TEST_ROOT}")
    message(FATAL_ERROR "Install-core check requires an absolute module and owned test root")
endif()
string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef nonce)
set(work "${TEST_ROOT}/selection-${nonce}")
set(build_core "${work}/build-core")
set(install_core "${work}/install-core")
file(MAKE_DIRECTORY "${work}/source" "${build_core}/include/dict"
    "${install_core}/bin" "${install_core}/lib" "${install_core}/include/dict")
# A mutable source header must not replace the retained compiled-header authority.
file(WRITE "${build_core}/include/dict/dict.h" "/* current source header differs */\n")
set(retained_header "${work}/compiled-dict.h")
file(WRITE "${retained_header}" "/* install-selection fixture header */\n")
file(WRITE "${install_core}/include/dict/dict.h" "/* install-selection fixture header */\n")
file(WRITE "${install_core}/bin/wikidict" "install-selection CLI fixture\n")
file(WRITE "${install_core}/lib/libdictffi.so" "install-selection FFI fixture\n")
file(WRITE "${work}/source/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 3.21)
project(InstallCoreSelection NONE)
set(WIKIDICT_EXECUTABLE "${BUILD_CORE}/bin/wikidict")
set(DICT_FFI_LIBRARY "${BUILD_CORE}/lib/libdictffi.so")
include("${INSTALL_CORE_MODULE}")
wikidict_select_install_core("${WIKIDICT_EXECUTABLE}" "${DICT_FFI_LIBRARY}"
    "${BUILD_CORE}/include/dict/dict.h")
if(NOT WIKIDICT_EXECUTABLE STREQUAL "${BUILD_CORE}/bin/wikidict"
        OR NOT DICT_FFI_LIBRARY STREQUAL "${BUILD_CORE}/lib/libdictffi.so")
    message(FATAL_ERROR "Install selection changed build-time inputs")
endif()
if(WIKIDICT_INSTALL_CORE_PREFIX STREQUAL "")
    if(NOT wikidict_install_executable STREQUAL WIKIDICT_EXECUTABLE
            OR NOT wikidict_install_ffi STREQUAL DICT_FFI_LIBRARY
            OR NOT wikidict_install_header STREQUAL "")
        message(FATAL_ERROR "Empty install prefix changed the default install")
    endif()
else()
    if(NOT wikidict_install_executable STREQUAL "${WIKIDICT_INSTALL_CORE_PREFIX}/bin/wikidict"
            OR NOT wikidict_install_ffi STREQUAL "${WIKIDICT_INSTALL_CORE_PREFIX}/lib/libdictffi.so"
            OR NOT wikidict_install_header STREQUAL "${WIKIDICT_INSTALL_CORE_PREFIX}/include/dict/dict.h")
        message(FATAL_ERROR "Install selection did not retain the complete paired core")
    endif()
endif()
]=])

function(configure_case name prefix expect_success)
    execute_process(COMMAND "${CMAKE_COMMAND}" -S "${work}/source" -B "${work}/${name}"
        "-DBUILD_CORE=${build_core}" "-DINSTALL_CORE_MODULE=${INSTALL_CORE_MODULE}"
        "-DWIKIDICT_INSTALL_CORE_PREFIX=${prefix}"
        "-DWIKIDICT_INSTALL_COMPILED_HEADER=${retained_header}"
        RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE diagnostic TIMEOUT 30)
    file(WRITE "${work}/${name}.stdout" "${output}")
    file(WRITE "${work}/${name}.stderr" "${diagnostic}")
    if(expect_success)
        if(NOT result STREQUAL "0")
            message(FATAL_ERROR "${name} configure failed; evidence: ${work}\n${diagnostic}")
        endif()
    else()
        if(result STREQUAL "0" OR NOT diagnostic MATCHES "WIKIDICT_INSTALL_CORE_PREFIX header does not match the compiled header")
            message(FATAL_ERROR "Header mismatch was not rejected for the expected reason; evidence: ${work}\n${diagnostic}")
        endif()
    endif()
endfunction()

configure_case(default "" TRUE)
configure_case(paired "${install_core}" TRUE)
file(WRITE "${install_core}/include/dict/dict.h" "/* incompatible fixture header */\n")
configure_case(mismatched-header "${install_core}" FALSE)
message(STATUS "Install-core selection checks passed; evidence: ${work}")
