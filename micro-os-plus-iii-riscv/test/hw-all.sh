#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# hw-all.sh — run ALL of this port's hardware tests on BOARD, one after another.
#
# A dispatcher and nothing else. Every board carries its own test/boards/<id>/hw-all.sh
# with the same interface, so this file has no case statement and no list of
# board names: adding a board adds a directory, exactly as it does for
# board.cmake, src/, include/ and test/.
#
#     BOARD=<id> test/hw-all.sh [tests...]   ->  test/boards/<id>/hw-all.sh [tests...]
#
# Default BOARD is milkv-duo.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD="${BOARD:-milkv-duo}"

SCRIPT="$HERE/boards/$BOARD/hw-all.sh"
if [[ ! -x "$SCRIPT" ]]; then
  echo "hw-all.sh: test/boards/$BOARD has no hw-all.sh" >&2
  echo "available boards:" >&2
  for d in "$HERE"/boards/*/; do
    b="$(basename "$d")"
    [[ -x "$d/hw-all.sh" ]] && echo "  $b" >&2
  done
  exit 2
fi

exec "$SCRIPT" "$@"
