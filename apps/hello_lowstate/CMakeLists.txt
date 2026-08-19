# hello_lowstate — first Layer-2 milestone: subscribe to rt/lf/lowstate, print state.
# Read-only. No motion commands.
add_executable(hello_lowstate main.cpp)

if(unitree_sdk2_FOUND)
  target_link_libraries(hello_lowstate PRIVATE unitree_sdk2)
else()
  # Manual wiring against an in-tree unitree_sdk2 checkout.
  target_include_directories(hello_lowstate PRIVATE
    ${UNITREE_SDK2_DIR}/include
    ${UNITREE_SDK2_DIR}/thirdparty/include)
  target_link_directories(hello_lowstate PRIVATE
    ${UNITREE_SDK2_DIR}/lib/aarch64)
  target_link_libraries(hello_lowstate PRIVATE unitree_sdk2 ddsc ddscxx pthread)
endif()
