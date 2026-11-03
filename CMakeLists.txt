cmake_minimum_required(VERSION 3.20)
project(InDe LANGUAGES CXX)
if(NOT APPLE)
  message(FATAL_ERROR "Use build.ps1 for Windows. This CMake target builds macOS modules.")
endif()
set(PCL_ROOT "" CACHE PATH "PixInsight Class Library source root")
set(PCL_LIBRARY_DIR "" CACHE PATH "Directory containing built PCL static libraries")
add_library(InDe SHARED src/InDeModule.cpp src/InDeProcess.cpp
  src/InDeWorker.cpp src/InDeInterface.cpp)
set_target_properties(InDe PROPERTIES PREFIX "" OUTPUT_NAME "InDe-pxm"
  CXX_STANDARD 20 CXX_STANDARD_REQUIRED YES
  CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN YES
  INSTALL_NAME_DIR "@executable_path" BUILD_WITH_INSTALL_NAME_DIR YES)
target_compile_definitions(InDe PRIVATE __PCL_MACOSX _REENTRANT)
target_include_directories(InDe PRIVATE "${PCL_ROOT}/include" "${PCL_ROOT}/src/3rdparty")
if(CMAKE_OSX_ARCHITECTURES STREQUAL "x86_64")
  target_compile_options(InDe PRIVATE -msse4.2)
endif()
target_compile_options(InDe PRIVATE -Wall -Wno-extern-c-compat)
foreach(lib PCL lz4 zstd zlib RFC6234 lcms cminpack)
  target_link_libraries(InDe PRIVATE "${PCL_LIBRARY_DIR}/lib${lib}-pxi.a")
endforeach()
target_link_libraries(InDe PRIVATE "-framework AppKit" "-framework ApplicationServices" pthread)
