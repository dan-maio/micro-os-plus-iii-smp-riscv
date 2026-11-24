# -----------------------------------------------------------------------------
# tests.cmake -- the Pico 2 (RISC-V) test set.
#
# The `qemu` images are built on the RV32 virt stand-in. The SMP tests drive
# both harts there too (qemu.sh starts QEMU with as many harts as the image
# was built for); the single-core ones run on one.
# -----------------------------------------------------------------------------

set (_pico2_smp_tests smp-test2 smp-test3 smp-test4 smp-test5 smp-test-ko smp-mat-test smp-test-nested
     smp-mat-test-ram smp-test-usb-cdc-acm smp-test-usb-hid)

# Tests that program RP2350 peripherals directly (TIMER0, SIO): hardware
# only, as on the Cortex-M Pico 2 board.
set (BOARD_TEST_HWD_ONLY smp-test0 smp-test3 smp-test4 smp-test5 smp-test-ko smp-mat-test smp-test-nested
     smp-mat-test-ram cmsis-os-validator-ram mutex-stress-ram rtos-apis-ram
     smp-test-usb-cdc-acm smp-test-usb-hid)

# The two USB device tests link TinyUSB with their class driver and its
# tusb_config.h. A plain Pico 2 has no WS2812 (the Cortex-M CDC test was
# brought up on an RP2350B-MINI-A, RGB LED on GPIO20): PICO2_HAS_WS2812 stays
# undefined, and ws2812.hpp's inline stubs stand in.
set (_usb_cdc_tests smp-test-usb-cdc-acm)
set (_usb_hid_tests smp-test-usb-hid)

function (board_test_sources _app _out)
  if ("${_app}" IN_LIST _usb_cdc_tests)
    set (${_out} ${UOS_BOARD_USB_CORE_SOURCES} ${UOS_BOARD_USB_CDC_SOURCES}
         PARENT_SCOPE)
  elseif ("${_app}" IN_LIST _usb_hid_tests)
    set (${_out} ${UOS_BOARD_USB_CORE_SOURCES} ${UOS_BOARD_USB_HID_SOURCES}
         PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()

function (board_test_includes _app _out)
  if ("${_app}" IN_LIST _usb_cdc_tests)
    set (${_out} "${UOS_BOARD_USB_CDC_INCLUDE}" ${UOS_BOARD_USB_INCLUDE}
         PARENT_SCOPE)
  elseif ("${_app}" IN_LIST _usb_hid_tests)
    set (${_out} "${UOS_BOARD_USB_HID_INCLUDE}" ${UOS_BOARD_USB_INCLUDE}
         PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()

# `<name>-ram`: the same program run from SRAM, loaded over the debugger
# (linker-ram.ld; hw.sh switches to a RAM session when the image's entry is
# in SRAM). Nothing is written to flash.
function (board_test_linker _app _out)
  if ("${_app}" MATCHES "-ram$")
    set (${_out} "${UOS_BOARD_SRC_DIR}/linker-ram.ld" PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()

# Bare-metal probes: no kernel (micro-os-plus::riscv-bare), their own main().
set (BOARD_TEST_NO_KERNEL smp-test0)

function (board_test_qemu_libs _app _out)
  if (UOS_QEMU_STANDIN)
    set (${_out} ${UOS_QEMU_STANDIN} PARENT_SCOPE)
  else ()
    set (${_out} micro-os-plus::riscv-qemu-virt32 PARENT_SCOPE)
  endif ()
endfunction ()

function (board_test_ncpu _app _out)
  if ("${_app}" IN_LIST _pico2_smp_tests)
    set (${_out} "${UOS_BOARD_NCPU}" PARENT_SCOPE)
  else ()
    set (${_out} 1 PARENT_SCOPE)
  endif ()
endfunction ()

function (board_test_qemu_ncpu _app _out)
  board_test_ncpu ("${_app}" _n)
  set (${_out} "${_n}" PARENT_SCOPE)
endfunction ()

# The kernel's harness suites, built only under the kernel's harness
# (platform riscv-pico2); single-core, as on the Cortex-M Pico 2.
set (BOARD_TEST_HARNESS_SUITES
     fp-switch mutex-stress rtos-apis cmsis-os-validator
     mutex-stress-ram rtos-apis-ram cmsis-os-validator-ram)

if (DEFINED PLATFORM_NAME AND NOT TARGET pico2-harness-suite)
  # What a harness platform gives a suite and a board app does not:
  #   OS_USE_OS_APP_CONFIG_H  the kernel reads the suite's os-app-config.h
  #                           only under it;
  #   the platform include    that file includes cmsis-plus/platform.h,
  #                           which is the harness platform's;
  #   --wrap=os_main          harness-suite.cpp defines __wrap_os_main(): run
  #                           the suite, print the RESULT line, end the run.
  add_library (pico2-harness-suite INTERFACE)
  target_compile_definitions (pico2-harness-suite INTERFACE
                              OS_USE_OS_APP_CONFIG_H UOS_HARNESS_SUITE
                              _POSIX_C_SOURCE=200809L _GNU_SOURCE)
  target_include_directories (pico2-harness-suite INTERFACE
                              "${CMAKE_SOURCE_DIR}/platforms/${PLATFORM_NAME}/include")
  target_link_options (pico2-harness-suite INTERFACE "-Wl,--wrap=os_main")
endif ()

function (board_test_libs _app _out)
  if ("${_app}" IN_LIST BOARD_TEST_HARNESS_SUITES)
    # A `-ram` suite is the same suite.
    string (REGEX REPLACE "-ram$" "" _suite "${_app}")
    set (_l test::${_suite} pico2-harness-suite)
    if (_suite STREQUAL "rtos-apis")
      # Its POSIX I/O and FatFs tests run on the kernel's POSIX layer.
      list (APPEND _l xpacks::chan-fatfs micro-os-plus::iii-posix-io)
    elseif (_suite STREQUAL "cmsis-os-validator")
      list (APPEND _l xpacks::arm-cmsis-os-validator)
    endif ()
    set (${_out} ${_l} PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()
