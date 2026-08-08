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
  LDB, configures SSSD, runs an NSS request, and checks the result against the
  selected affected-build or fixed-build expectation.
- `Containerfile` builds an otherwise stock SSSD checkout containing only the
  reproducer change, then executes the driver.
- `run-container.sh` is the host-side Docker wrapper.

## Run in a disposable container

The host needs a Docker-compatible container runtime, network access to pull
the Fedora base image and packages, and several GB of free disk space for the
image and full SSSD build. The first run builds SSSD from the current checkout
and can take several minutes, depending on the host.

### Confirm an affected build

From the SSSD source root, run:

```sh
bash contrib/memberof-watchdog-reproducer/run-container.sh
```

This is equivalent to setting `MEMBEROF_EXPECT_WATCHDOG=yes`. The test passes
only when SSSD logs a watchdog termination.

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

### Validate a candidate fix

Apply the reproducer changes to the checkout containing the candidate fix,
then run:

```sh
MEMBEROF_EXPECT_WATCHDOG=no \
  bash contrib/memberof-watchdog-reproducer/run-container.sh
```

In this mode the test passes only when the watchdog message is absent and the
NSS lookup exits successfully. The reproducer does not depend on a particular
fix; it must simply be present in the source checkout that the container
builds.

Every completed run prints the expected and observed watchdog state, the
`getent` exit status, the pass/fail result, and the in-container result path.
Exit status 0 means the selected expectation was met; exit status 1 means it
was not.

### Retain logs and results

The container is removed on exit. Bind-mount the result directory to retain
`status.txt`, the generator output, NSS output, LDAP fixture, and SSSD logs:

```sh
MEMBEROF_REPRO_RESULT_DIR="$PWD/memberof-repro-result" \
  bash contrib/memberof-watchdog-reproducer/run-container.sh
```

Use a new or empty result directory for each run. `CONTAINER_RUNTIME` may be
set to the name of a compatible runtime if `docker` is not the desired
command.

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

## Sharing the reproducer in a GitHub issue

Link to the immutable commit containing the `sysdb-tests` generator and this
directory. Maintainers should generate the cache with the supplied source and
scripts. Do not attach a generated LDB: it is tied to the SSSD/libldb build and
`memberOf` module that created it and is not a portable reproducer artifact.
