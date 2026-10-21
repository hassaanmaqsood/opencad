cmake_minimum_required(VERSION 3.16)
project(oracle_harness CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ABI include directory
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/../abi)
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)

# Try finding OpenCASCADE
find_package(OpenCASCADE QUIET)
if (OpenCASCADE_FOUND)
    message(STATUS "Found OpenCASCADE version ${OpenCASCADE_VERSION}")
    include_directories(${OpenCASCADE_INCLUDE_DIRS})
    set(HAVE_OPENCASCADE 1)
    add_compile_definitions(HAVE_OPENCASCADE=1)
else()
    message(STATUS "OpenCASCADE dev headers not found in system path; using built-in reference CAD engine fallback")
    set(HAVE_OPENCASCADE 0)
endif()

# Core sources
set(ORACLE_SRCS
    src/occ_oracle.cpp
    src/planegcs_oracle.cpp
    src/comparator.cpp
    src/fuzzer.cpp
    src/main.cpp
)

add_executable(cad_differential_runner ${ORACLE_SRCS})

if (OpenCASCADE_FOUND)
    target_link_libraries(cad_differential_runner PRIVATE
        TKernel
        TKMath
        TKG2d
        TKG3d
        TKBRep
        TKGeomBase
        TKGeomAlgo
        TKTopAlgo
        TKPrim
        TKBO
        TKBool
        TKMesh
    )
endif()

enable_testing()
add_test(NAME DiffPrimitivesTest COMMAND cad_differential_runner --suite=primitives --iterations=50)
