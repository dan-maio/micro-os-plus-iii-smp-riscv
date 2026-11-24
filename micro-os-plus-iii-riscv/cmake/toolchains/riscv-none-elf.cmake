# Toolchain: riscv-none-elf -- the xPack GNU RISC-V Embedded GCC (one
# toolchain for RV32 and RV64; the port selects rv64 with -march/-mabi).
#
# The kernel repository keeps the shared bare-metal preamble
# (cmake/toolchains/uos-bare-metal-common.cmake): newest xPack under
# ~/.local/xPacks first, else PATH; -DUOS_TOOLCHAIN_BIN=<dir> pins one. It is
# found beside this repository, as the kernel itself is.

set (CMAKE_SYSTEM_PROCESSOR riscv64)
set (UOS_TOOLCHAIN_PREFIX "riscv-none-elf-")
set (UOS_TOOLCHAIN_XPACK  "riscv-none-elf-gcc")

get_filename_component (_uos_rv_siblings "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set (_uos_rv_common "")
foreach (_cand IN ITEMS "${_uos_rv_siblings}/micro-os-plus-iii"
                        "${_uos_rv_siblings}/micro-os-plus-iii.git"
                        "${_uos_rv_siblings}/micro-os-plus-iii-smp"
                        "${_uos_rv_siblings}/micro-os-plus-iii-smp.git")
  if (NOT _uos_rv_common
      AND EXISTS "${_cand}/cmake/toolchains/uos-bare-metal-common.cmake")
    set (_uos_rv_common "${_cand}/cmake/toolchains/uos-bare-metal-common.cmake")
  endif ()
endforeach ()

if (NOT _uos_rv_common)
  message (FATAL_ERROR
    "riscv-none-elf.cmake: cannot find the kernel's uos-bare-metal-common.cmake.\n"
    "Clone micro-os-plus-iii beside micro-os-plus-iii-riscv.")
endif ()

include ("${_uos_rv_common}")
