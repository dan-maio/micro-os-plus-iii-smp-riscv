message (
  VERBOSE
  "Including tests/platforms/${PLATFORM_NAME}/cmake/definitions.cmake..."
)

set (xpack_platform_compile_definition "MICRO_OS_PLUS_PLATFORM_RISCV_CH32V307_EVT")

# The port's board id (micro-os-plus-iii-riscv/test/boards/ch32v307-evt).
set (BOARD "ch32v307-evt" CACHE STRING "Target board (the port's board id)" FORCE)
