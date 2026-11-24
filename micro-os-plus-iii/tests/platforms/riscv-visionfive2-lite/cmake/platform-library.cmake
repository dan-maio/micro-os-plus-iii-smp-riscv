message (
  VERBOSE
  "Including tests/platforms/${PLATFORM_NAME}/cmake/platform-library.cmake..."
)

# The platform library. The board apps link the port directly (its test/
# builder); this target is what a harness-only consumer would link.
add_library (platform-riscv-visionfive2-lite-interface INTERFACE EXCLUDE_FROM_ALL)
target_include_directories (platform-riscv-visionfive2-lite-interface INTERFACE "include")
target_compile_definitions (
  platform-riscv-visionfive2-lite-interface INTERFACE "${xpack_platform_compile_definition}" _GNU_SOURCE
)
target_link_libraries (
  platform-riscv-visionfive2-lite-interface
  INTERFACE
    # The RISC-V port: the kernel, the board's flags and sources.
    micro-os-plus::riscv
)

add_library (micro-os-plus::platform ALIAS platform-riscv-visionfive2-lite-interface)
message (VERBOSE "> micro-os-plus::platform -> platform-riscv-visionfive2-lite-interface")
