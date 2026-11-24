message (
  VERBOSE
  "Including tests/platforms/${PLATFORM_NAME}/cmake/definitions.cmake..."
)

set (xpack_platform_compile_definition "MICRO_OS_PLUS_PLATFORM_RISCV_VISIONFIVE2_LITE")

# The port's board id (micro-os-plus-iii-riscv/test/boards/visionfive2-lite).
set (BOARD "visionfive2-lite" CACHE STRING "Target board (the port's board id)" FORCE)
