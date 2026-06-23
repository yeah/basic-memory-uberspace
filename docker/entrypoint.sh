#!/bin/sh
set -e
mkdir -p /home/app/basic-memory
chown app:app /home/app /home/app/basic-memory 2>/dev/null || true
exec gosu app "$@"
