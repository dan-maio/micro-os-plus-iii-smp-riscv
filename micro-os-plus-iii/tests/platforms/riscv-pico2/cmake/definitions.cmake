message (
  VERBOSE
  "Including tests/platforms/${PLATFORM_NAME}/cmake/definitions.cmake..."
)

set (xpack_platform_compile_definition "MICRO_OS_PLUS_PLATFORM_RISCV_PICO2")

# The port's board id (micro-os-plus-iii-riscv/test/boards/pico2).
set (BOARD "pico2" CACHE STRING "Target board (the port's board id)" FORCE)
