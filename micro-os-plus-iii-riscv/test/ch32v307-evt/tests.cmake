# -----------------------------------------------------------------------------
# What the CH32V307V-EVT's tests need beyond the defaults.
#
# The kernel runs on the port's PFIC path (board.cmake RISCV_PFIC). Images
# run from flash (board linker.ld); there is no QEMU image.
#
#   board-basics   kernel-free (micro-os-plus::riscv-bare): start-up,
#                  clocks, console, LED, key, semihosting
#   smp-test1      the kernel, single core (the Pico 2's bring-up test)
#   pfic-test      the PFIC path itself: nesting, threshold, preemption
#   usb-cdc-stream a file round trip over USB HS (port P6), streamed; the PC
#                  side is usb-cdc-stream/usb-stream-host.py
#   the harness suites (below)
# -----------------------------------------------------------------------------

set (BOARD_TEST_NO_KERNEL board-basics)

# The kernel's harness suites, built only under the kernel's harness
# (platform riscv-ch32v307-evt): the directory under test/ch32v307-evt/
# carries only the name and the verdict (harness-suite.cpp).
set (BOARD_TEST_HARNESS_SUITES
     blinky fp-switch mutex-stress instrumentation rtos-apis cmsis-os-validator)

if (DEFINED PLATFORM_NAME AND NOT TARGET ch32v307-evt-harness-suite)
  # What a harness platform gives a suite and a board app does not:
  #   OS_USE_OS_APP_CONFIG_H  the kernel reads the suite's os-app-config.h
  #                           only under it (this board's include/ comes
  #                           first: include/cmsis-plus/os-app-config.h);
  #   the platform include    that file includes cmsis-plus/platform.h,
  #                           which is the harness platform's;
  #   --wrap=os_main          harness-suite.cpp defines __wrap_os_main().
  add_library (ch32v307-evt-harness-suite INTERFACE)
  target_compile_definitions (ch32v307-evt-harness-suite INTERFACE
                              OS_USE_OS_APP_CONFIG_H UOS_HARNESS_SUITE
                              _POSIX_C_SOURCE=200809L _GNU_SOURCE)
  target_include_directories (ch32v307-evt-harness-suite INTERFACE
                              "${CMAKE_SOURCE_DIR}/platforms/${PLATFORM_NAME}/include")
  target_link_options (ch32v307-evt-harness-suite INTERFACE "-Wl,--wrap=os_main")
endif ()

function (board_test_libs _app _out)
  if ("${_app}" IN_LIST BOARD_TEST_HARNESS_SUITES)
    set (_l test::${_app} ch32v307-evt-harness-suite)
    if (_app STREQUAL "rtos-apis")
      # Its POSIX I/O tests run on the kernel's POSIX layer (FatFs is left
      # out: include/cmsis-plus/os-app-config.h).
      list (APPEND _l xpacks::chan-fatfs micro-os-plus::iii-posix-io)
    elseif (_app STREQUAL "cmsis-os-validator")
      list (APPEND _l xpacks::arm-cmsis-os-validator)
    endif ()
    set (${_out} ${_l} PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()

# The USB tests: TinyUSB with the WCH USBHS driver (board.cmake
# UOS_BOARD_USB_*). Their tusb_config.h directory comes first.
set (_ch32_usb_tests usb-cdc-stream)

function (board_test_sources _app _out)
  if ("${_app}" IN_LIST _ch32_usb_tests)
    set (${_out} ${UOS_BOARD_USB_SOURCES} PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()

function (board_test_includes _app _out)
  if ("${_app}" IN_LIST _ch32_usb_tests)
    set (${_out} ${UOS_BOARD_USB_INCLUDE} PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()
