#!/bin/sh
# Start as root only long enough to make the data volume writable, then run the server as the
# unprivileged `command` user. Hosts such as Railway mount volumes owned by root, which the
# server (uid 1000) could not write to. Already non-root (e.g. `docker run --user`)? Run as is.
set -eu
if [ "$(id -u)" = "0" ]; then
    data_dir="$(dirname "${COMMAND_DB_PATH:-/data/command.db}")"
    mkdir -p "$data_dir"
    if [ "$(stat -c %u "$data_dir")" != "1000" ]; then
        chown -R command:command "$data_dir"
    fi
    exec setpriv --reuid=command --regid=command --init-groups command-server "$@"
fi
exec command-server "$@"
