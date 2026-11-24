# -----------------------------------------------------------------------------
# micro-os-plus-iii-riscv -- the RISC-V port of µOS++ III.
#
# The fourth architecture project, beside -cortexm, -aarch32 and -aarch64,
# and built the same way. It consumes the kernel; the kernel does not know
# this project exists, so the dependency runs one way.
#
# It holds no copy of the kernel. Clone it beside this one:
#
#   git clone .../micro-os-plus-iii.git
#
# and it is found automatically (also as micro-os-plus-iii.git, -smp, -smp.git).
#
# WHAT THIS PORT IS. RV64GC, machine mode, one hart. src/rtos/os-core.cpp is
# the upstream Cortex-M port's shape translated to RISC-V: the machine
# software interrupt (CLINT MSIP) stands in for PendSV, the machine timer for
# SysTick, mstatus.MIE for PRIMASK. OS_NCPU=1 and the kernel's SMP branches
# compile out, exactly as on the single-core Cortex-M boards.
#
# Boards are build configurations of this one port: -DBOARD=milkv-duo
# (default). A board is a directory test/boards/<id>/ with a board.cmake.
#
# Exports:
#   micro-os-plus::riscv            port + kernel + the selected board
#   micro-os-plus::riscv-bare       the board + start-up, trap entry and a
#                                   kernel-free runtime (no kernel)
#   micro-os-plus::riscv-qemu-virt  port + kernel + QEMU's virt machine, the
#                                   stand-in for a board QEMU does not model
# -----------------------------------------------------------------------------
cmake_minimum_required (VERSION 3.20)

project (micro-os-plus-iii-riscv LANGUAGES C CXX ASM)

set (UOS_RISCV_ROOT "${CMAKE_CURRENT_SOURCE_DIR}" CACHE INTERNAL "")

# -----------------------------------------------------------------------------
# The kernel: a sibling clone.
get_filename_component (_uos_siblings "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)

set (UOS_SMP_DIR "${_uos_siblings}/micro-os-plus-iii"
     CACHE PATH "µOS++ III kernel working copy")

if (NOT TARGET micro-os-plus::iii)
  foreach (_cand IN ITEMS "${UOS_SMP_DIR}" "${UOS_SMP_DIR}.git"
                          "${_uos_siblings}/micro-os-plus-iii-smp"
                          "${_uos_siblings}/micro-os-plus-iii-smp.git")
    if (NOT EXISTS "${UOS_SMP_DIR}/CMakeLists.txt"
        AND EXISTS "${_cand}/CMakeLists.txt")
      set (UOS_SMP_DIR "${_cand}" CACHE PATH "µOS++ III kernel working copy" FORCE)
    endif ()
  endforeach ()

  if (NOT EXISTS "${UOS_SMP_DIR}/CMakeLists.txt")
    message (FATAL_ERROR
      "Cannot find the kernel repository at ${UOS_SMP_DIR}.\n"
      "This project keeps no copy of it. Clone it beside this one:\n"
      "    git clone <remote>/micro-os-plus-iii.git\n"
      "or point at a working copy: cmake -DUOS_SMP_DIR=/path/to/it ...")
  endif ()

  add_subdirectory ("${UOS_SMP_DIR}" micro-os-plus-iii-smp)
endif ()

# -----------------------------------------------------------------------------
# Which board. Boards are DISCOVERED: every test/boards/<id>/board.cmake.
file (GLOB _board_decls CONFIGURE_DEPENDS
      "${CMAKE_CURRENT_SOURCE_DIR}/test/boards/*/board.cmake")
set (_board_ids "")
foreach (_decl IN LISTS _board_decls)
  get_filename_component (_dir "${_decl}" DIRECTORY)
  get_filename_component (_id "${_dir}" NAME)
  list (APPEND _board_ids "${_id}")
endforeach ()
list (SORT _board_ids)

set (BOARD "milkv-duo" CACHE STRING "Target board (one of: ${_board_ids})")
set_property (CACHE BOARD PROPERTY STRINGS ${_board_ids})

if (NOT BOARD IN_LIST _board_ids)
  message (FATAL_ERROR
    "BOARD=${BOARD} is not a board of this port.\n"
    "Available: ${_board_ids}\n"
    "A board is a directory under test/boards/ containing a board.cmake.")
endif ()

include ("${CMAKE_CURRENT_SOURCE_DIR}/test/boards/${BOARD}/board.cmake")

foreach (_required IN ITEMS UOS_BOARD_SRC_DIR UOS_BOARD_FLAGS UOS_BOARD_NCPU
                            UOS_BOARD_CAPS UOS_BOARD_LINKER_HW
                            UOS_BOARD_DEFINES)
  if (NOT DEFINED ${_required})
    message (FATAL_ERROR
      "test/boards/${BOARD}/board.cmake does not set ${_required}.")
  endif ()
endforeach ()

get_filename_component (UOS_BOARD_SRC_DIR "${UOS_BOARD_SRC_DIR}" ABSOLUTE)
foreach (_v IN ITEMS UOS_BOARD_SRC_DIR UOS_BOARD_NCPU UOS_BOARD_CAPS
                     UOS_BOARD_LINKER_HW UOS_BOARD_LINKER_QEMU)
  set (${_v} "${${_v}}" CACHE INTERNAL "board fact")
endforeach ()

# -----------------------------------------------------------------------------
# The ISA half: the same on every board.
set (_uos_riscv_port_sources
  "${CMAKE_CURRENT_SOURCE_DIR}/src/startup.S"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/trap.S"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/trap.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/startup.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/trace.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/syscalls.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/syscalls-time.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/mmu.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/soft-irq.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/semihosting-exit.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/rtos/os-core.cpp"
)

# One port target = the ISA half + one board (its include/ and src/).
#
#   uos_riscv_add_port (<name> <board dir> FLAGS ... DEFINES ... [LINKER x])
#
# defines <name>-board-interface (the board alone) and <name>-interface (that
# plus the port and the kernel). LINKER, when given, is added as -T: the QEMU
# stand-in carries its own script; a real board's script is chosen per
# variant by test/CMakeLists.txt instead.
function (uos_riscv_add_port _name _board_dir)
  cmake_parse_arguments (P "" "LINKER" "FLAGS;LINK_FLAGS;DEFINES;LIBS" ${ARGN})

  file (GLOB _bsrc CONFIGURE_DEPENDS
        "${_board_dir}/src/*.c" "${_board_dir}/src/*.cpp" "${_board_dir}/src/*.S")

  add_library (${_name}-board-interface INTERFACE)
  target_include_directories (${_name}-board-interface INTERFACE
                              "${_board_dir}/include"
                              "${CMAKE_CURRENT_SOURCE_DIR}/include")
  target_sources (${_name}-board-interface INTERFACE ${_bsrc})
  # __ARM_EABI__ is the kernel's name for "embedded, no OS underneath": its
  # malloc, exit/atexit, _sbrk, C++ runtime hooks, free-store set-up and
  # trace.cpp compile only under it. The AArch64 port defines it for the same
  # reason. include/riscv-eabi-compat.h (force-included) covers the one Arm
  # instruction it lets through; see the comment there.
  target_compile_definitions (${_name}-board-interface INTERFACE
                              ${P_DEFINES} __ARM_EABI__)
  target_compile_options (${_name}-board-interface INTERFACE ${P_FLAGS}
    "$<$<COMPILE_LANGUAGE:C,CXX>:SHELL:-include ${CMAKE_CURRENT_SOURCE_DIR}/include/riscv-eabi-compat.h>")
  target_link_options (${_name}-board-interface INTERFACE ${P_FLAGS}
    # One RAM region holds text and data (the image is loaded into DDR and
    # runs there), so the single LOAD segment is RWX by construction.
    "LINKER:--no-warn-rwx-segments")
  # Link-only flags, after FLAGS: the last -march chooses the multilib
  # (board.cmake, UOS_BOARD_LINK_FLAGS).
  if (P_LINK_FLAGS)
    target_link_options (${_name}-board-interface INTERFACE ${P_LINK_FLAGS})
  endif ()
  if (P_LINKER)
    target_link_options (${_name}-board-interface INTERFACE "-T${P_LINKER}")
  endif ()
  if (P_LIBS)
    target_link_libraries (${_name}-board-interface INTERFACE ${P_LIBS})
  endif ()

  # Without the kernel (BOARD_TEST_NO_KERNEL): the board, the start-up and
  # trap entry, and a kernel-free runtime (src/bare/runtime.cpp); the test
  # support headers (hw_result.hpp) but not its board contract, which is
  # about OS_NCPU and the scheduler.
  add_library (${_name}-bare-interface INTERFACE)
  target_sources (${_name}-bare-interface INTERFACE
    "${CMAKE_CURRENT_SOURCE_DIR}/src/startup.S"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/trap.S"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/bare/runtime.cpp")
  target_link_libraries (${_name}-bare-interface INTERFACE
    ${_name}-board-interface)
  target_include_directories (${_name}-bare-interface INTERFACE
    "$<TARGET_PROPERTY:micro-os-plus-iii-test-support-interface,INTERFACE_INCLUDE_DIRECTORIES>")

  add_library (${_name}-interface INTERFACE)
  target_sources (${_name}-interface INTERFACE ${_uos_riscv_port_sources})
  target_link_libraries (${_name}-interface INTERFACE
    ${_name}-board-interface
    micro-os-plus::iii
    # hw_result.hpp + the compile-time board contract (board-contract.cpp).
    micro-os-plus::test-support)
endfunction ()

# The selected board.
uos_riscv_add_port (micro-os-plus-iii-riscv "${UOS_BOARD_SRC_DIR}"
                    FLAGS ${UOS_BOARD_FLAGS}
                    LINK_FLAGS ${UOS_BOARD_LINK_FLAGS}
                    DEFINES ${UOS_BOARD_DEFINES}
                    LIBS ${UOS_BOARD_LIBS})
add_library (micro-os-plus::riscv ALIAS micro-os-plus-iii-riscv-interface)
add_library (micro-os-plus::riscv-bare ALIAS micro-os-plus-iii-riscv-bare-interface)

# The QEMU virt stand-in: generic RV64GC, no tuning for a particular core.
uos_riscv_add_port (micro-os-plus-iii-riscv-qemu-virt
                    "${CMAKE_CURRENT_SOURCE_DIR}/qemu/virt"
                    FLAGS -march=rv64imafdc_zicsr_zifencei -mabi=lp64d -mcmodel=medany
                    DEFINES SEMIHOST_TRAP_CHOSEN
                            "PORT_GREETING=\"µOS++ QEMU virt (RV64GC)\""
                    LINKER "${CMAKE_CURRENT_SOURCE_DIR}/qemu/virt/linker.ld")
add_library (micro-os-plus::riscv-qemu-virt
             ALIAS micro-os-plus-iii-riscv-qemu-virt-interface)

# The same virt machine as an RV32 hart without an FPU, compiled exactly as
# the RP2350's Hazard3 cores are (the pico-sdk's -march): the stand-in for
# RV32 boards, and the proof that the port is XLEN-generic.
set (UOS_RISCV_RV32_FLAGS
     -march=rv32ima_zicsr_zifencei_zba_zbb_zbs_zbkb_zca_zcb_zcmp -mabi=ilp32
     -mcmodel=medany
     CACHE INTERNAL "RV32 (Hazard3) code generation")
uos_riscv_add_port (micro-os-plus-iii-riscv-qemu-virt32
                    "${CMAKE_CURRENT_SOURCE_DIR}/qemu/virt"
                    FLAGS ${UOS_RISCV_RV32_FLAGS}
                    # The libraries with M, as the Pico 2 board links them
                    # (test/boards/pico2/board.cmake).
                    LINK_FLAGS -march=rv32imc_zicsr_zifencei
                    DEFINES SEMIHOST_TRAP_CHOSEN
                            "PORT_GREETING=\"µOS++ QEMU virt (RV32IMAC, Hazard3 code)\""
                    LINKER "${CMAKE_CURRENT_SOURCE_DIR}/qemu/virt/linker.ld")
add_library (micro-os-plus::riscv-qemu-virt32
             ALIAS micro-os-plus-iii-riscv-qemu-virt32-interface)

# Which stand-in a board's `qemu` images use. A board sets its default
# (UOS_BOARD_QEMU_LIB); this cache entry overrides it, e.g. to build the
# Duo's tests as RV32 (-DUOS_QEMU_STANDIN=micro-os-plus::riscv-qemu-virt32).
set (UOS_QEMU_STANDIN "" CACHE STRING
     "Override the board's QEMU stand-in library (empty: the board's choice)")

# Standalone: this repository is the top-level build (its own test/ builder
# registers CTest cases). Under the kernel's harness (tests/), the harness
# platform registers them instead.
set (UOS_RISCV_STANDALONE ${PROJECT_IS_TOP_LEVEL} CACHE INTERNAL "")

set (UOS_PORT_LIB      micro-os-plus::riscv      CACHE INTERNAL "")
set (UOS_PORT_BARE_LIB micro-os-plus::riscv-bare CACHE INTERNAL "")

if (PROJECT_IS_TOP_LEVEL AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/test/CMakeLists.txt")
  # The harness's naming: <app>-<variant>.elf, plus a <app>-hwd symlink to it
  # for the hardware runner (test/CMakeLists.txt).
  set (CMAKE_EXECUTABLE_SUFFIX ".elf")
  enable_testing ()
  add_subdirectory (test)
endif ()

message (STATUS "µOS++ III RISC-V port: micro-os-plus::riscv, board ${BOARD}")
