# -----------------------------------------------------------------------------
# tests/platforms/riscv-visionfive2-lite -- the StarFive VisionFive 2 Lite
# (JH-7110S, four SiFive U74, RV64GC) through the RISC-V port's own test
# builder.
#
# Every application is a directory under the port's test/visionfive2-lite/:
# its own board tests and the harness suites (placeholders whose sources are
# tests/sources/<suite>, wired by the port's tests.cmake). Every one runs on
# all four U74 (OS_NCPU = 4). QEMU does not model the JH-7110S and the port
# builds no emulated image for this board, so each application gets one
# CTest case:
#
#   <platform>-<app>-hwd    on the board, over JTAG: OpenOCD loads the image
#                           into DDR of a board stopped at the U-Boot prompt
#                           (label hwd; `test` excludes it)
# -----------------------------------------------------------------------------

message (VERBOSE "Processing 'tests/platforms/${PLATFORM_NAME}'...")

include ("cmake/platform-library.cmake")

include ("${UOS_RISCV_DIR}/test/boards/${BOARD}/board.cmake")

add_subdirectory ("${UOS_RISCV_DIR}/test" "port-tests/test")

set (_port_bin "${CMAKE_CURRENT_BINARY_DIR}/port-tests")
set (_port_test_dir "${UOS_RISCV_DIR}/test/${BOARD}")
set (_board_hw "${UOS_RISCV_DIR}/test/boards/${BOARD}/hw.sh")

file (GLOB _test_dirs LIST_DIRECTORIES true "${_port_test_dir}/*")
foreach (_dir IN LISTS _test_dirs)
  if (NOT IS_DIRECTORY "${_dir}")
    continue ()
  endif ()
  get_filename_component (_app "${_dir}" NAME)
  if (_app STREQUAL "include" OR _app STREQUAL "src")
    continue ()
  endif ()
  file (GLOB _srcs "${_dir}/*.cpp")
  if (NOT _srcs)
    continue ()
  endif ()

  # --- hwd ---------------------------------------------------------------
  add_test (
    NAME "${PLATFORM_NAME}-${_app}-hwd"
    COMMAND bash "${_board_hw}" "${_app}" 600
  )
  set_tests_properties (
    "${PLATFORM_NAME}-${_app}-hwd"
    PROPERTIES ENVIRONMENT "BUILD=${_port_bin}" LABELS "hwd" TIMEOUT 1200
  )
endforeach ()

message (STATUS "RISC-V visionfive2-lite: port tests + harness suites registered (${PLATFORM_NAME})")
