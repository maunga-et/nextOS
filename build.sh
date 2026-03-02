#!/bin/sh
# Default entry point: run the single full build pipeline.
# Use --streamline to run the legacy wrapper pipeline.

if [ "${1:-}" = "--streamline" ]; then
    shift
    exec ./build/streamline.sh "$@"
fi

exec ./full-build.sh "$@"
