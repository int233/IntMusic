cmake_minimum_required(VERSION 3.17)
project(IntMusic VERSION 0.1 LANGUAGES CXX)
set(CMAKE_VERBOSE_MAKEFILE ON)
# 设置C++标准
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
cmake_policy(SET CMP0007 NEW)
set(CMAKE_AUTORCC ON)

# 查找Qt组件
find_package(Qt6 6.8.3 REQUIRED COMPONENTS
    Core
    Gui
    Widgets
    Multimedia
    Sql
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

# 包含当前目录
set(CMAKE_INCLUDE_CURRENT_DIR ON)
# 配置TagLib构建
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

# 添加可执行文件
function(scan_sources dir result)
    file(GLOB_RECURSE sources "${dir}/*.cpp")
    set(${result} ${sources} PARENT_SCOPE)
endfunction()
scan_sources("app" INTMUSIC_SOURCES)
qt_add_executable(IntMusic 
    ${INTMUSIC_SOURCES} 
    resources.qrc
)

qt_add_translations(
    TARGETS IntMusic
    TS_FILES IntMusic_zh_CN.ts
)

# 包含目录
target_include_directories(IntMusic PRIVATE
    ${TAGLIB_INSTALL_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/app
)

target_compile_definitions(IntMusic PRIVATE 
    TAGLIB_STATIC
)

# 链接库
target_link_libraries(IntMusic PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Multimedia
    Qt6::Sql
    ${TAGLIB_INSTALL_DIR}/lib/${CMAKE_STATIC_LIBRARY_PREFIX}tag${CMAKE_STATIC_LIBRARY_SUFFIX}

    PkgConfig::AV
    PkgConfig::MARIADB
    # secur32
)

# 添加依赖关系
add_dependencies(IntMusic taglib)

include(GNUInstallDirs)

install(TARGETS IntMusic
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

    setup_autodeploy_from_template(IntMusic)
endif()