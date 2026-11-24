// The harness suite "blinky".
//
// Its sources are not here: they live in the kernel's harness,
// tests/sources/blinky/, and are named by board_test_libs() in
// test/ch32v307-evt/tests.cmake. This directory is where the application's NAME
// comes from (the port's builder builds one application per directory with a
// *.cpp), so the harness platform registers blinky-hwd like
// every other test.
//
// It also gives the suite the verdict a board run needs. A suite RETURNS its
// code from os_main(); the runners read a RESULT line and the semihosting
// exit. The suite is linked with -Wl,--wrap=os_main, so the kernel's call to
// os_main() lands here.

#include <harness-suite.hpp>

UOS_HARNESS_SUITE_VERDICT ("blinky")
