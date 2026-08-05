cmake_minimum_required(VERSION 3.31.6)

project(typing_dongnanya_rime LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)

get_filename_component(PROJECT_REPOSITORY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../.." ABSOLUTE)
set(LIBRIME_ROOT "${PROJECT_REPOSITORY_ROOT}/vendor/librime")

include(FetchContent)
set(BOOST_INCLUDE_LIBRARIES
    algorithm
    crc
    dll
    interprocess
    preprocessor
    range
    regex
    scope_exit
    signals2
    unordered
    utility
    uuid
    vmd)
FetchContent_Declare(
    boost
    URL https://github.com/boostorg/boost/releases/download/boost-1.89.0/boost-1.89.0-cmake.tar.xz
    URL_HASH SHA256=67acec02d0d118b5de9eb441f5fb707b3a1cdd884be00ca24b9a73c995511f74
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(boost)

set(YAML_CPP_BUILD_CONTRIB OFF CACHE BOOL "" FORCE)
set(YAML_CPP_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(YAML_CPP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(YAML_CPP_INSTALL OFF CACHE BOOL "" FORCE)
set(YAML_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(YAML_ENABLE_PIC ON CACHE BOOL "" FORCE)
add_subdirectory("${LIBRIME_ROOT}/deps/yaml-cpp" "${CMAKE_CURRENT_BINARY_DIR}/yaml-cpp")

set(LEVELDB_BUILD_BENCHMARKS OFF CACHE BOOL "" FORCE)
set(LEVELDB_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LEVELDB_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory("${LIBRIME_ROOT}/deps/leveldb" "${CMAKE_CURRENT_BINARY_DIR}/leveldb")

set(ENABLE_NATIVE_CODE OFF CACHE BOOL "" FORCE)
set(ENABLE_TOOLS OFF CACHE BOOL "" FORCE)
set(ENABLE_ASAN OFF CACHE BOOL "" FORCE)
set(ENABLE_UBSAN OFF CACHE BOOL "" FORCE)
set(ENABLE_GPERFTOOLS_PROFILER OFF CACHE BOOL "" FORCE)
add_subdirectory("${LIBRIME_ROOT}/deps/marisa-trie" "${CMAKE_CURRENT_BINARY_DIR}/marisa")

set(OPENCC_ROOT "${LIBRIME_ROOT}/deps/opencc")
set(OPENCC_SOURCE_ROOT "${OPENCC_ROOT}/src")
set(OPENCC_SOURCE_LIST
    Config.cpp
    Conversion.cpp
    ConversionChain.cpp
    Converter.cpp
    Dict.cpp
    DictConverter.cpp
    DictEntry.cpp
    DictGroup.cpp
    Lexicon.cpp
    MarisaDict.cpp
    MaxMatchSegmentation.cpp
    PhraseExtract.cpp
    PipelineConverter.cpp
    PluginSegmentation.cpp
    PrefixMatch.cpp
    SingleStageConverter.cpp
    ResourceProvider.cpp
    SerializableDict.cpp
    SerializedValues.cpp
    SimpleConverter.cpp
    Segmentation.cpp
    TextDict.cpp
    UTF8StringSlice.cpp
    UTF8Util.cpp
    BinaryDict.cpp
    DartsDict.cpp)
list(TRANSFORM OPENCC_SOURCE_LIST PREPEND "${OPENCC_SOURCE_ROOT}/")
add_library(opencc_runtime STATIC ${OPENCC_SOURCE_LIST})
target_include_directories(opencc_runtime
    PUBLIC "${OPENCC_SOURCE_ROOT}"
    PRIVATE
        "${OPENCC_ROOT}/deps/rapidjson-1.1.0"
        "${OPENCC_ROOT}/deps/tclap-1.2.5"
        "${OPENCC_ROOT}/deps/darts-clone-0.32h/include")
target_compile_definitions(opencc_runtime PRIVATE
    Opencc_BUILT_AS_STATIC
    OPENCC_SEGMENTATION_PLUGIN_DIR="")
target_link_libraries(opencc_runtime PUBLIC marisa PRIVATE dl)

file(GLOB RIME_API_SOURCES CONFIGURE_DEPENDS "${LIBRIME_ROOT}/src/*.cc")
file(GLOB RIME_BASE_SOURCES CONFIGURE_DEPENDS "${LIBRIME_ROOT}/src/rime/*.cc")
file(GLOB RIME_ALGORITHM_SOURCES CONFIGURE_DEPENDS "${LIBRIME_ROOT}/src/rime/algo/*.cc")
file(GLOB RIME_CONFIG_SOURCES CONFIGURE_DEPENDS "${LIBRIME_ROOT}/src/rime/config/*.cc")
file(GLOB RIME_DICTIONARY_SOURCES CONFIGURE_DEPENDS "${LIBRIME_ROOT}/src/rime/dict/*.cc")
file(GLOB RIME_GEAR_SOURCES CONFIGURE_DEPENDS "${LIBRIME_ROOT}/src/rime/gear/*.cc")
file(GLOB RIME_LEVER_SOURCES CONFIGURE_DEPENDS "${LIBRIME_ROOT}/src/rime/lever/*.cc")
set(RIME_GENERATED_INCLUDE_ROOT "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${RIME_GENERATED_INCLUDE_ROOT}/rime")
file(WRITE "${RIME_GENERATED_INCLUDE_ROOT}/rime/build_config.h" "#pragma once\n#define RIME_DATA_DIR \"rime-data\"\n#define RIME_PLUGINS_DIR \"rime-plugins\"\n")

add_library(rime_android STATIC
    ${RIME_API_SOURCES}
    ${RIME_BASE_SOURCES}
    ${RIME_ALGORITHM_SOURCES}
    ${RIME_CONFIG_SOURCES}
    ${RIME_DICTIONARY_SOURCES}
    ${RIME_GEAR_SOURCES}
    ${RIME_LEVER_SOURCES})
target_include_directories(rime_android PUBLIC
    "${RIME_GENERATED_INCLUDE_ROOT}"
    "${LIBRIME_ROOT}/src"
    "${LIBRIME_ROOT}/include")
target_compile_definitions(rime_android PRIVATE
    BOOST_DLL_USE_STD_FS
    RIME_EXTRA_MODULES=
    RIME_VERSION=\"1.17.0\")
target_link_libraries(rime_android
    PUBLIC
        Boost::regex
        Boost::algorithm
        Boost::crc
        Boost::interprocess
        Boost::preprocessor
        Boost::range
        Boost::scope_exit
        Boost::signals2
        Boost::unordered
        Boost::uuid
        Boost::vmd
        yaml-cpp
        leveldb
        marisa
        opencc_runtime)

add_library(typing_dongnanya_rime SHARED rime_jni.cpp)
target_include_directories(typing_dongnanya_rime PRIVATE
    "${RIME_GENERATED_INCLUDE_ROOT}"
    "${LIBRIME_ROOT}/src"
    "${LIBRIME_ROOT}/include")
target_compile_options(typing_dongnanya_rime PRIVATE -Wall -Wextra -Werror)
target_link_libraries(typing_dongnanya_rime PRIVATE rime_android android log)
