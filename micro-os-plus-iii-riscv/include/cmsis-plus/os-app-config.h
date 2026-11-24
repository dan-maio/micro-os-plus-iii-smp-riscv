/*
 * os-app-config.h -- application configuration for the RISC-V port.
 *
 * The kernel includes <cmsis-plus/os-app-config.h> under
 * OS_USE_OS_APP_CONFIG_H. This port's configuration comes from the build's
 * -D flags and port/os-c-decls.h, so this file holds no macros of its own.
 *
 * A harness suite built as a board app carries its own os-app-config.h, and
 * that file IS the configuration: hand over to it under the harness marker,
 * exactly as the AArch32 and Cortex-M ports do.
 */

#ifndef CMSIS_PLUS_OS_APP_CONFIG_H_
#define CMSIS_PLUS_OS_APP_CONFIG_H_

#if defined(UOS_HARNESS_SUITE)
#include_next <cmsis-plus/os-app-config.h>
#endif

#endif /* CMSIS_PLUS_OS_APP_CONFIG_H_ */
