# CMake toolchain for cross-compiling Go2 apps to the RK3588S2 (aarch64).
# Use focal-era aarch64 GCC so binaries match the Ubuntu 20.04 rootfs glibc.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# Override with -DCROSS=... if your triplet differs.
if(NOT DEFINED CROSS)
  set(CROSS aarch64-linux-gnu-)
endif()

set(CMAKE_C_COMPILER   ${CROSS}gcc)
set(CMAKE_CXX_COMPILER ${CROSS}g++)

# Point at the target sysroot / unitree_sdk2 install if you have one.
# set(CMAKE_SYSROOT /path/to/aarch64-sysroot)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
