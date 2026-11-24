message (
  VERBOSE
  "Including tests/platforms/${PLATFORM_NAME}/cmake/definitions.cmake..."
)

set (xpack_platform_compile_definition "MICRO_OS_PLUS_PLATFORM_RISCV_MILKV_DUO")

# The port's board id (micro-os-plus-iii-riscv/test/boards/milkv-duo).
set (BOARD "milkv-duo" CACHE STRING "Target board (the port's board id)" FORCE)
