# -----------------------------------------------------------------------------
# tests/platforms/riscv-mangopi-mq-pro -- the MangoPi MQ-Pro (Allwinner D1,
# T-Head C906, RV64GC) through the RISC-V port's own test builder.
#
# Every application is a directory under the port's test/mangopi-mq-pro/: its
# own board tests and the harness suites (placeholders whose sources are
# tests/sources/<suite>, wired by the port's tests.cmake).  Each gets the
# variants the port builder produces:
#
#   <platform>-<app>-qemu   on QEMU's virt machine -- QEMU does not model the
#                           D1, so the emulated image links the port's virt
#                           stand-in (micro-os-plus::riscv-qemu-virt)
#   <platform>-<app>-hwd    on the board, over xfel: hw.sh loads the image at
#                           0x40000000, the verdict comes back through the
#                           RTC registers, and the test resets to FEL (label
#                           hwd; `test` excludes it).  UART is left to the
#                           user.
#
# BOARD_TEST_HWD_ONLY / BOARD_TEST_QEMU_ONLY are honoured here so the CTest
# list matches the images the port actually built (semihosting-test is QEMU
# only on this board).
# -----------------------------------------------------------------------------

message (VERBOSE "Processing 'tests/platforms/${PLATFORM_NAME}'...")

include ("cmake/platform-library.cmake")

include ("${UOS_RISCV_DIR}/test/boards/${BOARD}/board.cmake")

# The port's test knobs, in this scope too, so the registration below sees
# the same HWD_ONLY / QEMU_ONLY lists as the port's test builder.
include ("${UOS_RISCV_DIR}/test/${BOARD}/tests.cmake")

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

  set (_has_qemu TRUE)
  set (_has_hwd TRUE)
  if ("${_app}" IN_LIST BOARD_TEST_QEMU_ONLY)
    set (_has_hwd FALSE)
  endif ()
  if ("${_app}" IN_LIST BOARD_TEST_HWD_ONLY)
    set (_has_qemu FALSE)
  endif ()

  # --- qemu --------------------------------------------------------------
  if (_has_qemu)
    add_test (
      NAME "${PLATFORM_NAME}-${_app}-qemu"
      COMMAND bash "${_board_qemu}" "${_app}"
    )
    set_tests_properties (
      "${PLATFORM_NAME}-${_app}-qemu"
      PROPERTIES ENVIRONMENT "BUILD=${_port_bin};SECS=600"
                 LABELS "qemu" TIMEOUT 900
    )
  endif ()

  # --- hwd ---------------------------------------------------------------
  if (_has_hwd)
    add_test (
      NAME "${PLATFORM_NAME}-${_app}-hwd"
      COMMAND bash "${_board_hw}" "${_app}" 600
    )
    set_tests_properties (
      "${PLATFORM_NAME}-${_app}-hwd"
      PROPERTIES ENVIRONMENT "BUILD=${_port_bin}" LABELS "hwd" TIMEOUT 1200
    )
  endif ()
endforeach ()

message (STATUS "RISC-V mangopi-mq-pro: port tests + harness suites registered (${PLATFORM_NAME})")
