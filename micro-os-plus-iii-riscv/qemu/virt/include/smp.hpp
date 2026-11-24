/*
 * smp.hpp -- board-contract memory map for QEMU virt (-m 128M).
 *
 * Copyright (c) 2026 Dan. MIT license.
 */
#pragma once

#include <cmsis-plus/rtos/port/os-decls.h>

#define PORT_RAM_BASE 0x80000000ULL
#define PORT_RAM_END 0x88000000ULL
