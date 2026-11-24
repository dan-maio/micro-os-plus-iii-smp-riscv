message (
  VERBOSE
  "Including tests/platforms/${PLATFORM_NAME}/cmake/dependencies-folders.cmake..."
)

set (
  xpack_dependencies_folders
  # The portable harness suites. Their sources become test::<suite>, which the
  # port's board_test_libs() names for the placeholder applications under
  # test/visionfive2-lite/ (built with OS_NCPU=4: every suite runs on the four U74).
  "${CMAKE_SOURCE_DIR}/sources/blinky"
  "${CMAKE_SOURCE_DIR}/sources/fp-switch"
  "${CMAKE_SOURCE_DIR}/sources/mutex-stress"
  "${CMAKE_SOURCE_DIR}/sources/instrumentation"
  "${CMAKE_SOURCE_DIR}/sources/rtos-apis"
  "${CMAKE_SOURCE_DIR}/sources/cmsis-os-validator"
  # The SOURCE_DIR is the `tests` folder.
  "${CMAKE_SOURCE_DIR}/xpacks/@xpacks/arm-cmsis-rtos-validator"
  "${CMAKE_SOURCE_DIR}/xpacks/@xpacks/chan-fatfs"
)
