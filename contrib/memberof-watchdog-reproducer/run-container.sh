#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

runtime=${CONTAINER_RUNTIME:-docker}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
source_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
image=${MEMBEROF_REPRO_IMAGE:-sssd-memberof-watchdog-reproducer:local}
expect_watchdog=${MEMBEROF_EXPECT_WATCHDOG:-yes}
host_result_dir=${MEMBEROF_REPRO_RESULT_DIR:-}

case "$expect_watchdog" in
yes|no) ;;
*)
    echo "MEMBEROF_EXPECT_WATCHDOG must be 'yes' or 'no'" >&2
    exit 2
    ;;
esac

command -v "$runtime" >/dev/null || {
    echo "container runtime not found: $runtime" >&2
    exit 1
}

"$runtime" build --tag "$image" --file "$script_dir/Containerfile" "$source_root"

run_args=(
    --rm
    --init
    --env "MEMBEROF_EXPECT_WATCHDOG=$expect_watchdog"
)

if [[ -n "$host_result_dir" ]]; then
    mkdir -p "$host_result_dir"
    host_result_dir=$(CDPATH='' cd -- "$host_result_dir" && pwd)
    run_args+=(--volume "$host_result_dir:/work/result:Z")
fi

set +e
"$runtime" run "${run_args[@]}" "$image"
run_status=$?
set -e

if [[ -n "$host_result_dir" ]]; then
    echo "Retained result files: $host_result_dir"
fi

exit "$run_status"
