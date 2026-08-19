cmake_minimum_required(VERSION 3.16)
project(rk3588s2_go2_apps CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# unitree_sdk2 is fetched into ../third_party/unitree_sdk2 by scripts/fetch_sources.sh.
# Prefer an installed package; fall back to the in-tree source.
set(UNITREE_SDK2_DIR "${CMAKE_SOURCE_DIR}/../third_party/unitree_sdk2" CACHE PATH "unitree_sdk2 root")

find_package(unitree_sdk2 QUIET)
if(NOT unitree_sdk2_FOUND)
  message(STATUS "unitree_sdk2 package not found; expecting headers/libs under ${UNITREE_SDK2_DIR}")
endif()

add_subdirectory(hello_lowstate)
