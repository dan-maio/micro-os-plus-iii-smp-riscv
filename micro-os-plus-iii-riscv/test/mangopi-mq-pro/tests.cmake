# -----------------------------------------------------------------------------
# What the MangoPi MQ-Pro's tests need beyond the defaults.
#
# Every test is a board test: it has its own os_main(), links
# micro-os-plus::riscv and ends with a RESULT line.  On hardware that verdict
# comes back over UART0 and the test resets the SoC into FEL (test/<board>/
# include/hw_result.hpp); under QEMU it goes through semihosting.
#
# The test set is the portable RISC-V one of the Milk-V Duo, adapted for the
# D1: one C906 hart, no USB device stack, no CV1800B timers/PLIC test.  The
# `qemu` image of every test runs on QEMU's virt machine, as on the Duo.
# -----------------------------------------------------------------------------

# No JTAG probe on this setup: semihosting-test needs a debugger/emulator, so
# it is built for QEMU only and never appears as a hardware image.
set (BOARD_TEST_QEMU_ONLY semihosting-test)

# wifi-net needs the RTL8723DS on SDC1 and a real access point: there is
# nothing for QEMU to model, so it has a hardware image only.
set (BOARD_TEST_HWD_ONLY wifi-net wifi-ram-disk)

# wifi-ram-disk: wifi-net's radio + lwIP stack, unchanged, plus the 512 MiB
# RAM disk (0x60000000, the upper half of the 1 GiB board) and the TCP file
# server shared with the VisionFive 2 Lite tests, and FatFs (the copy under
# that board's emmc-fs-test/fatfs).  The board has no Ethernet: Wi-Fi only.
set (_mqpro_ramdisk_dir "${CMAKE_CURRENT_LIST_DIR}/../visionfive2-lite/vf2-wifi-ram-disk")
set (_mqpro_fatfs_dir "${CMAKE_CURRENT_LIST_DIR}/../visionfive2-lite/emmc-fs-test/fatfs")

# What wifi-net associates with.  No credentials in the repository: pass them
# on the cmake line, e.g.
#   -DWIFI_TEST_SSID=myssid -DWIFI_TEST_PASS=mypassphrase
# A build without them still runs the radio and the scan, and fails the join
# step with that reason in the log.
set (WIFI_TEST_SSID "" CACHE STRING "wifi-net: SSID to join")
set (WIFI_TEST_PASS "" CACHE STRING "wifi-net: WPA2 passphrase")
set (WIFI_TEST_GATEWAY "192.168.1.1" CACHE STRING "wifi-net: gateway to ping")
set (WIFI_TEST_PEER "" CACHE STRING "wifi-net: optional second host to ping")

# The kernels' harness suites: their sources live in the kernel's harness
# (tests/sources/<suite>), and the directory here carries only the name and
# the verdict.  Built only when the kernel harness drives the build.
set (BOARD_TEST_HARNESS_SUITES
     blinky fp-switch mutex-stress instrumentation rtos-apis cmsis-os-validator)

if (DEFINED PLATFORM_NAME AND NOT TARGET mangopi-mq-pro-harness-suite)
  add_library (mangopi-mq-pro-harness-suite INTERFACE)
  target_compile_definitions (mangopi-mq-pro-harness-suite INTERFACE
                              OS_USE_OS_APP_CONFIG_H UOS_HARNESS_SUITE
                              _POSIX_C_SOURCE=200809L _GNU_SOURCE)
  target_include_directories (mangopi-mq-pro-harness-suite INTERFACE
                              "${CMAKE_SOURCE_DIR}/platforms/${PLATFORM_NAME}/include")
  target_link_options (mangopi-mq-pro-harness-suite INTERFACE
                       "-Wl,--wrap=os_main")
endif ()

function (board_test_qemu_libs _app _out)
  if (UOS_QEMU_STANDIN)
    set (${_out} ${UOS_QEMU_STANDIN} PARENT_SCOPE)
  else ()
    set (${_out} micro-os-plus::riscv-qemu-virt PARENT_SCOPE)
  endif ()
endfunction ()

# wifi-net brings the Wi-Fi stack with it: the D1 SDIO host, the rtw88 port,
# the crypto, lwIP and the two glues.  All of it lives under
# test/boards/<board>/wifi (board support), not in the test directory, so that
# the test stays one main.cpp.
function (board_test_sources _app _out)
  if ("${_app}" STREQUAL "wifi-net" OR "${_app}" STREQUAL "wifi-ram-disk")
    file (GLOB_RECURSE _wifi_sources CONFIGURE_DEPENDS
          "${UOS_BOARD_SRC_DIR}/wifi/src/*.cpp"
          "${UOS_BOARD_SRC_DIR}/wifi/src/*.c"
          "${UOS_BOARD_SRC_DIR}/wifi/src/wifi/rtw/*.S"
          "${CMAKE_CURRENT_SOURCE_DIR}/third_party/lwip/src/core/*.c"
          "${CMAKE_CURRENT_SOURCE_DIR}/third_party/lwip/src/core/ipv4/*.c"
          "${CMAKE_CURRENT_SOURCE_DIR}/third_party/lwip/src/netif/*.c")
    if ("${_app}" STREQUAL "wifi-ram-disk")
      list (APPEND _wifi_sources
            "${_mqpro_ramdisk_dir}/ram-disk.cpp"
            "${_mqpro_ramdisk_dir}/file-server.cpp"
            "${_mqpro_fatfs_dir}/source/ff.c"
            "${_mqpro_fatfs_dir}/source/ffunicode.c")
    endif ()
    set (${_out} ${_wifi_sources} PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()

function (board_test_includes _app _out)
  if ("${_app}" STREQUAL "wifi-ram-disk")
    set (${_out}
         "${UOS_BOARD_SRC_DIR}/wifi/src"
         "${UOS_BOARD_SRC_DIR}/wifi/src/net"
         "${UOS_BOARD_SRC_DIR}/wifi/src/wifi"
         "${UOS_BOARD_SRC_DIR}/wifi/src/wifi/rtw"
         "${CMAKE_CURRENT_SOURCE_DIR}/third_party/lwip/src/include"
         "${_mqpro_ramdisk_dir}"
         "${_mqpro_fatfs_dir}/include"
         PARENT_SCOPE)
  elseif ("${_app}" STREQUAL "wifi-net")
    set (${_out}
         "${UOS_BOARD_SRC_DIR}/wifi/src"
         "${UOS_BOARD_SRC_DIR}/wifi/src/net"
         "${UOS_BOARD_SRC_DIR}/wifi/src/wifi"
         "${UOS_BOARD_SRC_DIR}/wifi/src/wifi/rtw"
         "${CMAKE_CURRENT_SOURCE_DIR}/third_party/lwip/src/include"
         PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()

function (board_test_defines _app _out)
  if ("${_app}" STREQUAL "wifi-net" OR "${_app}" STREQUAL "wifi-ram-disk")
    set (${_out}
         "WIFI_TEST_SSID=\"${WIFI_TEST_SSID}\""
         "WIFI_TEST_PASS=\"${WIFI_TEST_PASS}\""
         "WIFI_TEST_GATEWAY=\"${WIFI_TEST_GATEWAY}\""
         "WIFI_TEST_PEER=\"${WIFI_TEST_PEER}\""
         PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()

function (board_test_libs _app _out)
  if ("${_app}" IN_LIST BOARD_TEST_HARNESS_SUITES)
    set (_l test::${_app} mangopi-mq-pro-harness-suite)
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

# The single-hart smp-mat run with the requested problem size: 8 row blocks
# of 40 (N/B = 8, a multiple of OS_NCPU=1).
function (board_test_options _app _out)
  if ("${_app}" STREQUAL "smp-mat-test")
    set (${_out} -DSMP_MAT_N=320 -DSMP_MAT_B=40 PARENT_SCOPE)
  else ()
    set (${_out} "" PARENT_SCOPE)
  endif ()
endfunction ()
