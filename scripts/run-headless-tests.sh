#!/bin/zsh
# Runs the unit tests via SwiftPM (no app window). Tests only touch $TMPDIR fixtures.
cd "$(dirname "$0")/headless-tests" && swift test "$@"
