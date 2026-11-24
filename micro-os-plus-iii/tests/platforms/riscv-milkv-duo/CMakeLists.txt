# -----------------------------------------------------------------------------
# tests/platforms/riscv-milkv-duo -- the Milk-V Duo (CV1800B, C906, RV64GC)
# through the RISC-V port's own test builder.
#
# Every application is a directory under the port's test/milkv-duo/: its own
# board tests and the harness suites (placeholders whose sources are
# tests/sources/<suite>, wired by the port's tests.cmake). Each gets two
# images and two CTest cases:
#
#   <platform>-<app>-qemu   on QEMU's virt machine -- QEMU does not model the
#                           CV1800B, so the port builds the emulated image
#                           against virt (micro-os-plus::riscv-qemu-virt)
#   <platform>-<app>-hwd    on the board, over JTAG: OpenOCD loads the image
#                           into DDR of a board booted from the minimal fip
#                           (label hwd; one per power cycle; `test` excludes it)
# -----------------------------------------------------------------------------

message (VERBOSE "Processing 'tests/platforms/${PLATFORM_NAME}'...")

include ("cmake/platform-library.cmake")

include ("${UOS_RISCV_DIR}/test/boards/${BOARD}/board.cmake")

add_subdirectory ("${UOS_RISCV_DIR}/test" "port-tests/test")

set (_port_bin "${CMAKE_CURRENT_BINARY_DIR}/port-tests")
set (_port_test_dir "${UOS_RISCV_DIR}/test/${BOARD}")
set (_board_qemu "${UOS_RISCV_DIR}/test/boards/${BOARD}/qemu.sh")
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

  # --- qemu --------------------------------------------------------------
  add_test (
    NAME "${PLATFORM_NAME}-${_app}-qemu"
    COMMAND bash "${_board_qemu}" "${_app}"
  )
  set_tests_properties (
    "${PLATFORM_NAME}-${_app}-qemu"
    PROPERTIES ENVIRONMENT "BUILD=${_port_bin};SECS=600"
               LABELS "qemu" TIMEOUT 900
  )

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

message (STATUS "RISC-V milkv-duo: port tests + harness suites registered (${PLATFORM_NAME})")
