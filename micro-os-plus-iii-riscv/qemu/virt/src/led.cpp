/*
 * led.cpp -- QEMU virt: a virtual LED.
 *
 * Copyright (c) 2026 Dan. MIT license.
 */

#include <led.hpp>

namespace
{
  volatile bool state = false;
}

namespace led
{
  void
  init (void)
  {
    state = false;
  }

  void
  on (void)
  {
    state = true;
  }

  void
  off (void)
  {
    state = false;
  }

  void
  toggle (void)
  {
    state = !state;
  }

  bool
  is_on (void)
  {
    return state;
  }
} // namespace led
