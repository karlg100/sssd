# Synthetic same-GID memberOf watchdog reproducer

This directory contains a public, synthetic reproducer for the SSSD
`memberOf` watchdog failure. It contains no deployment identities, directory
data, or host configuration.

The reproducer creates a cache with this shape:

| Object | Count | Purpose |
| --- | ---: | --- |
| `repro-stale-group@FILES` direct members | 708 | 150% of the observed 472 direct members |
| Direct parents per child | 143 | stale group plus 142 peer parent groups |
| Inherited ancestors per child | 20 | nested membership coverage |
| Pre-trigger `memberOf` values per child | 163 | 143 direct plus 20 inherited |

The stale group has no parent `memberOf` entries and no `ghost` entries. An
incoming group named `repro-incoming-group@FILES` is absent from the cache but
has the stale group's non-zero GID, `610000`.

On the legacy code path, this request follows:

```text
sysdb_store_group(new name, existing GID)
  -> sysdb_store_new_group()
  -> sysdb_delete_group(domain, NULL, gid)
  -> memberOf delete processing for all 708 direct members
```

At the observed 90--124 ms per child, this workload takes roughly 64--88
seconds, well beyond the default watchdog deadline of three missed
`timeout = 10` heartbeats.

## Contents

- `setup-disposable-ldap.sh` creates and starts a local OpenLDAP server with
  only the synthetic group required to trigger the collision.
- `run-container-test.sh` is the in-container test driver. It generates the
  LDB, configures SSSD, runs an NSS request, and asserts that stock SSSD logs
  a watchdog termination.
- `Containerfile` builds an otherwise stock SSSD checkout containing only the
  reproducer change, then executes the driver.
- `run-container.sh` is the host-side Docker wrapper.

## Run in a disposable container

From the SSSD source root, run:

```sh
bash contrib/memberof-watchdog-reproducer/run-container.sh
```

The wrapper builds a Fedora 43 image from the current checkout. It
installs build dependencies, compiles and installs SSSD, creates a local LDAP
server on `127.0.0.1:1389`, and runs the trigger with `timeout = 10`.

The expected result on an affected build is a log line containing:

```text
was terminated by own WATCHDOG
```

Validation of this fixture on 2026-08-06 with the stock source build in the
container produced the same-GID collision at 13:56:40 and the watchdog
termination at 13:57:11 (31 seconds later).

The container is removed on exit. To retain `/work/result` from a failed run,
override `CONTAINER_RUNTIME` with a compatible runtime and invoke the
Containerfile directly without `--rm`.

## Generate only the cache

The generator is built into `sysdb-tests` by the source change. In a configured
build with the Check development dependency installed:

```sh
make ldb_mod_test_dir sysdb-tests
ln -sf memberof.so ldb_mod_test_dir/memberof.la
LDB_MODULES_PATH="$PWD/ldb_mod_test_dir" \
  ./sysdb-tests --generate-memberof-watchdog-cache
```

The generated `cache_FILES.ldb` and `timestamps_FILES.ldb` are placed under
the build's configured test directory and their location is printed by the
program. Generate and consume the LDB with the same SSSD/libldb build and
matching `memberOf` module; it is not a portable cache format.

The Fedora container driver also applies a Fedora-specific libldb module-name
workaround before generation. Prefer the container path for an issue-ready
reproduction on Fedora.

`--run-memberof-watchdog-trigger` generates a fresh cache and times the
same-GID operation in-process. It cannot itself produce a watchdog event,
because `sysdb-tests` is not supervised by `sssd_be`.

## Suggested GitHub issue attachments

Attach the source diff adding the two `sysdb-tests` options, this directory,
and SHA-256 hashes of any generated LDBs. The LDB binary is optional: maintainers
should normally regenerate it from the supplied source and scripts.
