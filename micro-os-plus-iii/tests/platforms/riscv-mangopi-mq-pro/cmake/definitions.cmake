message (
  VERBOSE
  "Including tests/platforms/${PLATFORM_NAME}/cmake/definitions.cmake..."
)

set (xpack_platform_compile_definition "MICRO_OS_PLUS_PLATFORM_RISCV_MANGOPI_MQ_PRO")

# The port's board id (micro-os-plus-iii-riscv/test/boards/mangopi-mq-pro).
set (BOARD "mangopi-mq-pro" CACHE STRING "Target board (the port's board id)" FORCE)
