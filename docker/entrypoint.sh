#!/bin/sh
set -e

# Named volumes are mounted root-owned. If this service has /data mounted
# (Basic Memory and WsgiDAV do), make sure the notes directory exists and is
# owned by the unprivileged user before we drop into it. The gateway has no
# /data mount, so this is skipped there.
if [ -d /data ]; then
    mkdir -p /data/basic-memory
    chown app:app /data /data/basic-memory 2>/dev/null || true
fi

exec gosu app "$@"
