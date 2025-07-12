cmake_minimum_required(VERSION 3.17)
project(IntMusic VERSION 0.1 LANGUAGES CXX)
set(CMAKE_VERBOSE_MAKEFILE ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
cmake_policy(SET CMP0007 NEW)
set(CMAKE_AUTORCC ON)

# 查找Qt组件
find_package(Qt6 6.8.3 REQUIRED COMPONENTS
    Core
    Gui
    Widgets
    Sql
    Network
    LinguistTools
)
find_package(PkgConfig REQUIRED)
pkg_check_modules(AV REQUIRED IMPORTED_TARGET
    libavformat
    libavcodec
    libswscale
    libswresample
    libavutil
)
pkg_check_modules(MARIADB REQUIRED IMPORTED_TARGET libmariadb)

qt_standard_project_setup()
set(CMAKE_INCLUDE_CURRENT_DIR ON)

# -------------------- 配置 TagLib 构建 --------------------
include(ExternalProject)
set(TAGLIB_VERSION 2.0.2)
set(TAGLIB_INSTALL_DIR ${CMAKE_BINARY_DIR}/taglib-install)

set(EP_CMAKE_ARGS
    -DCMAKE_INSTALL_PREFIX=${TAGLIB_INSTALL_DIR}
    -DWITH_ZLIB=OFF
    -DWITH_MP4=ON
    -DBUILD_TESTING=OFF
    -DBUILD_SHARED_LIBS=OFF
)

if(CMAKE_TOOLCHAIN_FILE)
    list(APPEND EP_CMAKE_ARGS -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE})
endif()

ExternalProject_Add(
    taglib
    GIT_REPOSITORY "https://github.com/taglib/taglib.git"
    GIT_TAG "v${TAGLIB_VERSION}"
    GIT_SHALLOW TRUE
    GIT_PROGRESS TRUE

    CMAKE_ARGS ${EP_CMAKE_ARGS}

    BUILD_BYPRODUCTS 
        ${TAGLIB_INSTALL_DIR}/lib/${CMAKE_STATIC_LIBRARY_PREFIX}tag${CMAKE_STATIC_LIBRARY_SUFFIX}
)
set(TAGLIB_LIBRARIES ${TAGLIB_INSTALL_DIR}/lib/${CMAKE_STATIC_LIBRARY_PREFIX}tag${CMAKE_STATIC_LIBRARY_SUFFIX})
set(TAGLIB_INCLUDE_DIRS ${TAGLIB_INSTALL_DIR}/include)

# -------------------- 配置 BASS --------------------
set(BASS_INSTALL_DIR ${CMAKE_BINARY_DIR}/bass-install)
set(BASS_SOURCE_DIR ${CMAKE_BINARY_DIR}/bass_project-prefix/src/bass_project)
set(BASSFLAC_SOURCE_DIR ${CMAKE_BINARY_DIR}/bassflac_project-prefix/src/bassflac_project)
set(BASS_INCLUDE_DIRS ${BASS_INSTALL_DIR}/include)
set(BASS_LIB_DIR ${BASS_INSTALL_DIR}/lib)
set(BASS_BIN_DIR ${BASS_INSTALL_DIR}/bin)

ExternalProject_Add(
    bass_project
    URL "https://www.un4seen.com/files/bass24.zip" # Windows 版本
    DOWNLOAD_NO_PROGRESS 1
    SOURCE_DIR ${CMAKE_BINARY_DIR}/bass_src
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""

    INSTALL_COMMAND
        ${CMAKE_COMMAND} -E make_directory ${BASS_INCLUDE_DIRS} ${BASS_LIB_DIR} ${BASS_BIN_DIR} &&
        ${CMAKE_COMMAND} -E copy ${BASS_SOURCE_DIR}/c/bass.h ${BASS_INCLUDE_DIRS}/bass.h &&
        ${CMAKE_COMMAND} -E copy ${BASS_SOURCE_DIR}/c/x64/bass.lib ${BASS_LIB_DIR}/bass.lib &&
        ${CMAKE_COMMAND} -E copy ${BASS_SOURCE_DIR}/x64/bass.dll ${BASS_BIN_DIR}/bass.dll
)

ExternalProject_Add(
    bassflac_project
    URL "https://www.un4seen.com/files/bassflac24.zip"
    DOWNLOAD_NO_PROGRESS 1
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND
        ${CMAKE_COMMAND} -E copy ${BASSFLAC_SOURCE_DIR}/c/bassflac.h ${BASS_INCLUDE_DIRS}/bassflac.h &&
        ${CMAKE_COMMAND} -E copy ${BASSFLAC_SOURCE_DIR}/c/x64/bassflac.lib ${BASS_LIB_DIR}/bassflac.lib &&
        ${CMAKE_COMMAND} -E copy ${BASSFLAC_SOURCE_DIR}/x64/bassflac.dll ${BASS_BIN_DIR}/bassflac.dll
)

set(BASS_LIBRARIES
    ${BASS_LIB_DIR}/bass.lib
    ${BASS_LIB_DIR}/bassflac.lib
)

# -------------------- 定义可执行文件 --------------------
function(scan_sources dir result)
    file(GLOB_RECURSE sources "${dir}/*.cpp")
    set(${result} ${sources} PARENT_SCOPE)
endfunction()

# --- 构建后端 Server ---
scan_sources("src/server" SERVER_SOURCES)
scan_sources("src/utils" UTILS_SOURCES)
if(SERVER_SOURCES)
    add_executable(IntMusicServer 
        ${SERVER_SOURCES}
        ${UTILS_SOURCES}
        resources.qrc
    )
    
    target_include_directories(IntMusicServer PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src/server
        ${CMAKE_CURRENT_SOURCE_DIR}/src/utils
        ${TAGLIB_INCLUDE_DIRS}
        ${BASS_INCLUDE_DIRS}
    )
    target_compile_definitions(IntMusicServer PRIVATE TAGLIB_STATIC)
    
    target_link_libraries(IntMusicServer PRIVATE
        Qt6::Core
        Qt6::Gui
        Qt6::Widgets
        Qt6::Sql
        Qt6::Network
        ${TAGLIB_LIBRARIES}
        PkgConfig::AV
        PkgConfig::MARIADB
        # BASS
    )
    add_dependencies(IntMusicServer taglib)
else()
    message(STATUS "No sources found for server, skipping IntMusicServer target.")
endif()

# -------------------- 安装与部署 --------------------

include(GNUInstallDirs)

install(
    FILES ${BASS_BIN_DIR}/bass.dll ${BASS_BIN_DIR}/bassflac.dll
    DESTINATION ${CMAKE_INSTALL_BINDIR}
    COMPONENT Runtime
)

install(TARGETS IntMusicServer 
    BUNDLE  DESTINATION .
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
)



if(APPLE)
set_target_properties(IntMusic PROPERTIES
    MACOSX_BUNDLE TRUE
)
endif()

set(deploy_tool_options_arg "")
if(APPLE)
    # set(deploy_tool_options_arg --hardened-runtime)
elseif(WIN32)
    set(deploy_tool_options_arg --no-compiler-runtime)
endif()

if(WIN32)
    function(setup_autodeploy_from_template TARGET)
        set(TARGET_NAME ${TARGET})
        set(MXE_QT_ROOT "/opt/mxe/usr/x86_64-w64-mingw32.shared/qt6")
        set(MXE_COMMON_BIN_DIR "/opt/mxe/usr/x86_64-w64-mingw32.shared/bin")
        set(QT_PLUGIN_DIR "${MXE_QT_ROOT}/plugins")
        set(SEARCH_PATHS "${MXE_QT_ROOT}/bin;${MXE_COMMON_BIN_DIR}")

        set(DEPLOY_SCRIPT_TEMPLATE "${CMAKE_CURRENT_SOURCE_DIR}/autodeploy.cmake.in")
        set(FINAL_DEPLOY_SCRIPT "${CMAKE_CURRENT_BINARY_DIR}/autodeploy_${TARGET}.cmake")
        
        configure_file(
            ${DEPLOY_SCRIPT_TEMPLATE}
            ${FINAL_DEPLOY_SCRIPT}
            @ONLY
        )
        
        message(STATUS "Generated deployment script: ${FINAL_DEPLOY_SCRIPT}")

        install(SCRIPT ${FINAL_DEPLOY_SCRIPT})

    endfunction()

    setup_autodeploy_from_template(IntMusicServer)
endif()