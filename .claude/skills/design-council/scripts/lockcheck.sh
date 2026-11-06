#!/bin/zsh
# Is the Mac's screen locked? Window captures of a locked screen come out empty, and in-app snapshots
# (`cacheDisplay`) draw the glass toolbar buttons as blank white pills — so Mac shots wait for an unlocked screen.
#   lockcheck.sh   → prints «locked: 1|nil onConsole: …», exits 1 when locked
LOCKCHECK=/tmp/wp-lockcheck
if [[ ! -x $LOCKCHECK ]]; then
  print -r -- 'import CoreGraphics
import Foundation
let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
print("locked:", d["CGSSessionScreenIsLocked"] ?? "nil", "onConsole:", d["kCGSSessionOnConsoleKey"] ?? "nil")' > /tmp/wp-lockcheck.swift
  swiftc -O /tmp/wp-lockcheck.swift -o $LOCKCHECK
fi
state=$($LOCKCHECK)
print -r -- $state
[[ $state != *'locked: 1'* ]]
