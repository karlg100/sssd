#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
    echo "usage: $0 start|stop WORKDIR" >&2
    exit 2
}

action=${1:-}
workdir=${2:-}

test -n "$action" && test -n "$workdir" || usage

case "$action" in
start|stop) ;;
*) usage ;;
esac

pid_file="$workdir/slapd.pid"
port=1389
base_dn='dc=repro,dc=test'
schema_dir=${LDAP_SCHEMA_DIR:-/etc/openldap/schema}

if test "$action" = stop; then
    if test -r "$pid_file"; then
        kill "$(cat "$pid_file")" 2>/dev/null || true
        rm -f "$pid_file"
    fi
    exit 0
fi

for command in slapadd slapd ldapsearch; do
    command -v "$command" >/dev/null || {
        echo "missing required command: $command" >&2
        exit 1
    }
done

for schema in core.schema cosine.schema nis.schema; do
    test -r "$schema_dir/$schema" || {
        echo "missing OpenLDAP schema: $schema_dir/$schema" >&2
        exit 1
    }
done

test ! -e "$workdir" || {
    echo "LDAP work directory already exists: $workdir" >&2
    exit 1
}

install -d -m 0700 "$workdir/db"
cat > "$workdir/slapd.conf" <<EOF
include $schema_dir/core.schema
include $schema_dir/cosine.schema
include $schema_dir/nis.schema
pidfile $pid_file
argsfile $workdir/slapd.args
database mdb
suffix "$base_dn"
rootdn "cn=admin,$base_dn"
rootpw repro-secret
directory $workdir/db
EOF

cat > "$workdir/repro.ldif" <<'EOF'
dn: dc=repro,dc=test
objectClass: top
objectClass: domain
dc: repro

dn: ou=groups,dc=repro,dc=test
objectClass: top
objectClass: organizationalUnit
ou: groups

dn: cn=repro-incoming-group,ou=groups,dc=repro,dc=test
objectClass: top
objectClass: posixGroup
cn: repro-incoming-group
gidNumber: 610000
EOF

slapadd -f "$workdir/slapd.conf" -l "$workdir/repro.ldif"
slapd -d 0 -f "$workdir/slapd.conf" -h "ldap://127.0.0.1:$port/" &
slapd_pid=$!
printf '%s\n' "$slapd_pid" > "$pid_file"

for _ in $(seq 1 100); do
    if ldapsearch -LLL -x -H "ldap://127.0.0.1:$port" -b "$base_dn" \
        '(objectClass=*)' dn >/dev/null 2>&1; then
        exit 0
    fi
    sleep 0.1
done

kill "$slapd_pid" 2>/dev/null || true
rm -f "$pid_file"
echo 'OpenLDAP did not become ready' >&2
exit 1
