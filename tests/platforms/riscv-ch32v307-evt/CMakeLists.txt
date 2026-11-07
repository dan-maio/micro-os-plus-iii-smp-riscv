# -----------------------------------------------------------------------------
# tests/platforms/riscv-ch32v307-evt -- the WCH CH32V307V-EVT-R1 (CH32V307,
# one QingKe V4F core, RV32IMAFC) through the RISC-V port's own test builder.
#
# Every application is a directory under the port's test/ch32v307-evt/: its
# own board tests and the harness suites (placeholders whose sources are
# tests/sources/<suite>, wired by the port's tests.cmake). The port runs its
# PFIC path there (RISCV_PFIC). QEMU does not model the chip, so each
# application gets one CTest case:
#
#   <platform>-<app>-hwd    on the board, over the on-board WCH-LinkE:
#                           hw.sh programs the image into flash and runs it
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

message (STATUS "RISC-V ch32v307-evt: port tests + harness suites registered (${PLATFORM_NAME})")
