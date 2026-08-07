#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

source_root=${SOURCE_ROOT:-/src}
result_dir=${RESULT_DIR:-/work/result}
test_dir=${TEST_DIR:-/work/test}
ldap_dir="$result_dir/ldap"
sssd_log="$result_dir/sssd.stderr.log"
sssd_prefix=/usr/local
sssd_state_dir="$sssd_prefix/var/lib/sss"
sssd_log_dir="$sssd_prefix/var/log/sssd"
sssd_config_dir="$sssd_prefix/etc/sssd"
sssd_pid=''

cleanup() {
    test -z "$sssd_pid" || kill "$sssd_pid" 2>/dev/null || true
    "$source_root/contrib/memberof-watchdog-reproducer/setup-disposable-ldap.sh" \
        stop "$ldap_dir" || true
}
trap cleanup EXIT

install -d -m 0700 "$result_dir" "$test_dir"
rm -rf "$sssd_state_dir" "$sssd_log_dir" /var/lib/sss /var/log/sssd
# The monitor creates config.ldb before changing privileges, while its
# children open and update the synthetic cache as the sssd user.  libtdb also
# creates companion state in this directory.  This is a disposable container;
# cache files and the configuration itself retain restrictive permissions.
install -d -m 0777 "$sssd_state_dir/db"
install -d -m 0777 "$sssd_state_dir/mc" "$sssd_state_dir/pipes" \
    "$sssd_state_dir/pipes/private" "$sssd_log_dir"
install -d -m 0755 "$sssd_config_dir" "$sssd_prefix/var/run/sssd"
ln -s "$sssd_state_dir" /var/lib/sss
ln -s "$sssd_log_dir" /var/log/sssd

"$source_root/contrib/memberof-watchdog-reproducer/setup-disposable-ldap.sh" \
    start "$ldap_dir"

export LDB_MODULES_PATH="$source_root/ldb_mod_test_dir"
# Fedora's libldb loader asks for the platform module suffix (.la), while the
# SSSD test build intentionally places the ELF module here as memberof.so.
# The alias is an ELF target, so dlopen() loads it normally.
ln -sf memberof.so "$LDB_MODULES_PATH/memberof.la"
# Fedora 43 also installs a libtool metadata file at the system LDB module
# location.  libldb may create the confdb before SSSD has selected the test
# module directory, so make that metadata name resolve to the same test-built
# ELF module.  The container is disposable and this never touches the host.
if [[ -f /usr/lib64/samba/ldb/memberof.la ]]; then
    ln -sf "$LDB_MODULES_PATH/memberof.so" /usr/lib64/samba/ldb/memberof.la
fi
"$source_root/sysdb-tests" --generate-memberof-watchdog-cache \
    > "$result_dir/generator.log" 2>&1

cache_dir="$test_dir/tp_sysdb_tests-sysdb-tests"
test -f "$cache_dir/cache_FILES.ldb"
test -f "$cache_dir/timestamps_FILES.ldb"
# The monitor and its unprivileged children open these pre-generated TDB
# files at different points in startup.  They are synthetic and live only in
# the disposable container, so keep the harness insensitive to that UID
# transition. The configuration database remains root-owned and mode 0600.
install -m 0666 "$cache_dir/cache_FILES.ldb" \
    "$sssd_state_dir/db/cache_FILES.ldb"
install -m 0666 "$cache_dir/timestamps_FILES.ldb" \
    "$sssd_state_dir/db/timestamps_FILES.ldb"

cat > "$sssd_config_dir/sssd.conf" <<'EOF'
[sssd]
services = nss, pam
domains = FILES

[domain/FILES]
id_provider = ldap
auth_provider = none
ldap_uri = ldap://127.0.0.1:1389
ldap_search_base = dc=repro,dc=test
ldap_group_search_base = ou=groups,dc=repro,dc=test
ldap_schema = rfc2307
ldap_id_use_start_tls = false
cache_credentials = false
enumerate = false
ignore_group_members = false
timeout = 10
debug_level = 9

[nss]
debug_level = 9
EOF
chown root:root "$sssd_config_dir/sssd.conf"
chmod 0600 "$sssd_config_dir/sssd.conf"

LDB_MODULES_PATH="$source_root/ldb_mod_test_dir" "$sssd_prefix/sbin/sssd" -i -d 9 \
    > "$sssd_log" 2>&1 &
sssd_pid=$!

for _ in $(seq 1 100); do
    test -S /var/lib/sss/pipes/nss && break
    sleep 0.1
done
test -S /var/lib/sss/pipes/nss

set +e
timeout 120 getent -s sss group repro-incoming-group@FILES \
    > "$result_dir/getent.out" 2> "$result_dir/getent.err"
getent_status=$?
set -e
printf 'getent_status=%s\n' "$getent_status" > "$result_dir/status.txt"

sleep 2
cat "$sssd_log" /var/log/sssd/*.log 2>/dev/null > "$result_dir/sssd.all.log" || true
grep -q 'was terminated by own WATCHDOG' "$result_dir/sssd.all.log"

printf 'watchdog_reproduced=yes\n' >> "$result_dir/status.txt"
