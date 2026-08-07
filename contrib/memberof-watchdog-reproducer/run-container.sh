#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

runtime=${CONTAINER_RUNTIME:-docker}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
source_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
image=${MEMBEROF_REPRO_IMAGE:-sssd-memberof-watchdog-reproducer:local}

command -v "$runtime" >/dev/null || {
    echo "container runtime not found: $runtime" >&2
    exit 1
}

"$runtime" build --tag "$image" --file "$script_dir/Containerfile" "$source_root"
"$runtime" run --rm --init "$image"
