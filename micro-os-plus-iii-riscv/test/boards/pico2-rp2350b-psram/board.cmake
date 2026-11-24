# -----------------------------------------------------------------------------
# board.cmake -- WeAct RP2350B (16 MB flash, 8 MB PSRAM) on its two Hazard3
# cores: the Cortex-M pico2-rp2350b-psram board, RISC-V.
#
# The same SoC as the Pico 2 in its 48-GPIO package, so it shares the Pico 2
# board's sources and headers (test/boards/pico2/src, include); what differs
# is set here: UART0 on GPIO12/13, the 16 MB flash, and (for the tests that
# ask for it) the 8 MB PSRAM on QMI chip-select 1 = GPIO0. Its own probe
# (c251:f001) and runner: hw.sh in this directory.
# -----------------------------------------------------------------------------

include ("${CMAKE_CURRENT_LIST_DIR}/../pico2/board.cmake")

set (UOS_BOARD_LINKER_HW "${CMAKE_CURRENT_LIST_DIR}/linker.ld")
set (UOS_BOARD_LINKER_RAM "${CMAKE_CURRENT_LIST_DIR}/../pico2/linker-ram.ld")

set (UOS_BOARD_DEFINES
     SEMIHOST_TRAP_CHOSEN
     PICO2_UART_TX_PIN=12
     PICO2_UART_RX_PIN=13
     PICO2_LED_PIN=25
     "PORT_GREETING=\"µOS++ WeAct RP2350B (16 MB flash + 8 MB PSRAM, 2x Hazard3 RV32)\"")
