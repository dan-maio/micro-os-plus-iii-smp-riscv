# -----------------------------------------------------------------------------
# Milk-V Duo (64 MB) -- Sophgo CV1800B, one T-Head C906 (RV64GC) driven by
# µOS++ in machine mode, 64 MiB DDR2.
#
# One file per board, discovered by the presence of this file. Nothing in the
# port's own CMakeLists knows this board exists.
# -----------------------------------------------------------------------------

set (UOS_BOARD_SRC_DIR "${CMAKE_CURRENT_LIST_DIR}")

# RV64GC with the double-float ABI: the C906 has the F and D extensions, and
# the port saves the FP register file on every trap. medany: the image lives
# at 0x80050000, outside the +-2 GiB of address 0 that medlow assumes.
set (UOS_BOARD_FLAGS -march=rv64imafdc_zicsr_zifencei -mabi=lp64d
                     -mcmodel=medany -mtune=thead-c906)
set (UOS_BOARD_NCPU  1)

# What this port can drive on this board. The test matrix asks about
# capabilities, never about board names.
set (UOS_BOARD_CAPS  led uart semihosting mmu fpu)

# The hardware image: loaded into DDR at 0x80050000 by OpenOCD (hw.sh).
set (UOS_BOARD_LINKER_HW "${UOS_BOARD_SRC_DIR}/linker.ld")

# QEMU does not model the CV1800B. The `qemu` image of every test runs on
# QEMU's virt machine instead: the board's tests.cmake replaces the board
# with micro-os-plus::riscv-qemu-virt, which carries its own linker script.
# A value is still needed here to request the `qemu` variant at all.
set (UOS_BOARD_LINKER_QEMU "${UOS_RISCV_ROOT}/qemu/virt/linker.ld")

set (UOS_BOARD_LIBS "")

# SEMIHOST_TRAP_CHOSEN: the board contract asks every semihosted board to say
# which trap its debugger expects. RISC-V has exactly one (the slli/ebreak/
# srai sequence, semihosting.hpp), so there is no second define to choose.
set (UOS_BOARD_DEFINES
     SEMIHOST_TRAP_CHOSEN
     "PORT_GREETING=\"µOS++ Milk-V Duo (CV1800B, T-Head C906 RV64GC)\"")

# The USB device stack for the two USB tests: the TinyUSB core and class
# drivers the Pico 2 carries (test/boards/pico2/usb/tinyusb, upstream commit
# 91fbbd192), the upstream DWC2 driver of the same commit with this board's
# platform header (usb/dwc2/dwc2_cv180x.h), the bring-up (usb/duo-usb.cpp,
# BL2's sequence), and the portable CDC/HID glue and descriptors of the
# Pico 2. Linked only into the USB tests (test/milkv-duo/tests.cmake).
set (_pico2_usb "${CMAKE_CURRENT_LIST_DIR}/../pico2/usb")
set (UOS_BOARD_USB_INCLUDE
     "${CMAKE_CURRENT_LIST_DIR}/usb"
     "${CMAKE_CURRENT_LIST_DIR}/usb/dwc2"
     "${_pico2_usb}/tinyusb")
set (UOS_BOARD_USB_CORE_SOURCES
     "${_pico2_usb}/tinyusb/tusb.c"
     "${_pico2_usb}/tinyusb/common/tusb_fifo.c"
     "${_pico2_usb}/tinyusb/device/usbd.c"
     "${CMAKE_CURRENT_LIST_DIR}/usb/dwc2/dcd_dwc2.c"
     "${CMAKE_CURRENT_LIST_DIR}/usb/dwc2/dwc2_common.c"
     "${CMAKE_CURRENT_LIST_DIR}/usb/duo-usb.cpp")
set (UOS_BOARD_USB_CDC_INCLUDE "${CMAKE_CURRENT_LIST_DIR}/usb/cdc" "${_pico2_usb}/cdc")
set (UOS_BOARD_USB_CDC_SOURCES
     "${_pico2_usb}/tinyusb/class/cdc/cdc_device.c"
     "${_pico2_usb}/cdc/usb_descriptors.c"
     "${_pico2_usb}/cdc/usb_cdc.c")
set (UOS_BOARD_USB_HID_INCLUDE "${CMAKE_CURRENT_LIST_DIR}/usb/hid" "${_pico2_usb}/hid")
set (UOS_BOARD_USB_HID_SOURCES
     "${_pico2_usb}/tinyusb/class/hid/hid_device.c"
     "${_pico2_usb}/hid/usb_descriptors.c"
     "${_pico2_usb}/hid/usb_hid.c")
