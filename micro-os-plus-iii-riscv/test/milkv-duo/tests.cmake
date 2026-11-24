# -----------------------------------------------------------------------------
# What the Milk-V Duo's tests need beyond the defaults.
#
# Every test is a board test: it has its own os_main(), links
# micro-os-plus::riscv and ends with a RESULT line and a semihosting exit.
#
# The `qemu` image. QEMU does not model the CV1800B, so the emulated image of
# each test links the port against QEMU's virt machine instead of this board
# (micro-os-plus::riscv-qemu-virt: the same port core, a virt CLINT, an
# NS16550 console, a virtual LED, its own linker script). The test's sources
# are unchanged; only what runs under them differs -- exactly how the
# Cortex-M port's pico2 runs its tests on QEMU.
# -----------------------------------------------------------------------------

# Hardware only: smp-test-nested drives the CV1800B's PLIC, timers and UART4,
# which QEMU's virt machine does not have.
set (BOARD_TEST_HWD_ONLY smp-test-nested smp-test-usb-cdc-acm smp-test-usb-hid)

# The two USB device tests: TinyUSB (DWC2, slave mode) with their class driver
# and their tusb_config.h -- whose directory goes first on the include path.
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
    set (${_out} ${UOS_BOARD_USB_CDC_INCLUDE} ${UOS_BOARD_USB_INCLUDE}
         PARENT_SCOPE)
  elseif ("${_app}" IN_LIST _usb_hid_tests)
    set (${_out} ${UOS_BOARD_USB_HID_INCLUDE} ${UOS_BOARD_USB_INCLUDE}
         PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()

function (board_test_qemu_libs _app _out)
  if (UOS_QEMU_STANDIN)
    set (${_out} ${UOS_QEMU_STANDIN} PARENT_SCOPE)
  else ()
    set (${_out} micro-os-plus::riscv-qemu-virt PARENT_SCOPE)
  endif ()
endfunction ()

# -----------------------------------------------------------------------------
# The harness suites.
#
# They are not board tests: their sources live in the kernel's harness,
# tests/sources/<suite>/, and the directory under test/milkv-duo/ carries
# only the name and the verdict (harness-suite.cpp). The harness platform
# (tests/platforms/riscv-milkv-duo) add_subdirectory()s those sources into
# test::<suite>; naming that library here brings its sources AND its own
# cmsis-plus/os-app-config.h, which the port's os-app-config.h hands over to
# (UOS_HARNESS_SUITE). The same arrangement as the Nucleo-F411RE and the
# Raspberry Pi boards.
#
# The suites run under the kernel's scalar (non-SMP) scheduler: this port
# has one hart.
set (BOARD_TEST_HARNESS_SUITES
     blinky fp-switch mutex-stress instrumentation rtos-apis cmsis-os-validator)

if (DEFINED PLATFORM_NAME AND NOT TARGET milkv-duo-harness-suite)
  # What a harness platform gives a suite and a board app does not:
  #   OS_USE_OS_APP_CONFIG_H  the kernel reads the suite's os-app-config.h
  #                           only under it;
  #   the platform include    that file includes cmsis-plus/platform.h,
  #                           which is the harness platform's;
  #   --wrap=os_main          harness-suite.cpp defines __wrap_os_main(): run
  #                           the suite, print the RESULT line, end the run.
  add_library (milkv-duo-harness-suite INTERFACE)
  target_compile_definitions (milkv-duo-harness-suite INTERFACE
                              OS_USE_OS_APP_CONFIG_H UOS_HARNESS_SUITE
                              _POSIX_C_SOURCE=200809L _GNU_SOURCE)
  target_include_directories (milkv-duo-harness-suite INTERFACE
                              "${CMAKE_SOURCE_DIR}/platforms/${PLATFORM_NAME}/include")
  target_link_options (milkv-duo-harness-suite INTERFACE "-Wl,--wrap=os_main")
endif ()

function (board_test_libs _app _out)
  if ("${_app}" IN_LIST BOARD_TEST_HARNESS_SUITES)
    set (_l test::${_app} milkv-duo-harness-suite)
    if (_app STREQUAL "rtos-apis")
      # Its POSIX I/O and FatFs tests run on the kernel's POSIX layer.
      list (APPEND _l xpacks::chan-fatfs micro-os-plus::iii-posix-io)
    elseif (_app STREQUAL "cmsis-os-validator")
      list (APPEND _l xpacks::arm-cmsis-os-validator)
    endif ()
    set (${_out} ${_l} PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()
