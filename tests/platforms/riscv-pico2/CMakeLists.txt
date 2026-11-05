# -----------------------------------------------------------------------------
# tests/platforms/riscv-pico2 -- the Raspberry Pi Pico 2 (RP2350, 2x Hazard3 RV32)
# through the RISC-V port's own test builder.
#
# Every application is a directory under the port's test/pico2/: its own
# board tests and the harness suites (placeholders whose sources are
# tests/sources/<suite>, wired by the port's tests.cmake). Each gets two
# images and two CTest cases:
#
#   <platform>-<app>-qemu   on QEMU's virt machine -- QEMU does not model the
#                           RP2350, so the port builds the emulated image
#                           against virt, RV32 (micro-os-plus::riscv-qemu-virt32)
#   <platform>-<app>-hwd    on the board: the Raspberry Pi Debug Probe (SWD)
#                           and the Raspberry Pi OpenOCD program it into flash
#                           and run it (label hwd; `test` excludes it)
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

  # --- qemu (only where the port built one: some Pico 2 tests program
  # RP2350 peripherals and are hardware only) -------------------------------
  if (TARGET "${_app}-qemu")
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
  add_test (
    NAME "${PLATFORM_NAME}-${_app}-hwd"
    COMMAND bash "${_board_hw}" "${_app}" 600
  )
  set_tests_properties (
    "${PLATFORM_NAME}-${_app}-hwd"
    PROPERTIES ENVIRONMENT "BUILD=${_port_bin}" LABELS "hwd" TIMEOUT 1200
  )
endforeach ()

message (STATUS "RISC-V pico2: port tests + harness suites registered (${PLATFORM_NAME})")
