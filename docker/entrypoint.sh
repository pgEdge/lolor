#!/bin/bash
set -e

cd /home/pgedge/pgedge
. pg${PG_VER}/pg${PG_VER}.env
echo ". /home/pgedge/pgedge/pg${PG_VER}/pg${PG_VER}.env" >> /home/pgedge/.bashrc

# Initialize the cluster.  This replaces `pgedge setup` from the
# deprecated pgedge CLI.
initdb -D "$PGDATA" -U admin --encoding=UTF8 --locale=C

cat >> "$PGDATA/postgresql.conf" <<_EOF_
listen_addresses = '*'
wal_level = logical
track_commit_timestamp = on
max_worker_processes = 32
max_replication_slots = 32
max_wal_senders = 32
shared_preload_libraries = 'spock'
spock.conflict_resolution = 'last_update_wins'
spock.save_resolutions = on
_EOF_

cat >> "$PGDATA/pg_hba.conf" <<_EOF_
# Trust connections from the peer nodes and the tester
host all all 0.0.0.0/0 trust
_EOF_

pg_ctl -D "$PGDATA" -l /home/pgedge/logfile.log -o "-k /tmp" -w start

while ! pg_isready -h /tmp; do
  echo "Waiting for PostgreSQL to become ready..."
  sleep 1
done

# The admin user is what the tests connect as; the pgedge user is used for
# the spock node and subscription DSNs (and matches the OS user, so plain
# psql on the nodes works).
psql -U admin -d postgres -h /tmp -v ON_ERROR_STOP=1 <<_EOF_
ALTER USER admin PASSWORD 'password';
CREATE ROLE pgedge SUPERUSER LOGIN;
CREATE DATABASE demo OWNER admin;
_EOF_

echo "==========Creating tables and repsets=========="
psql -U admin -d demo -h /tmp -v ON_ERROR_STOP=1 <<_EOF_
CREATE EXTENSION spock;
SELECT spock.node_create('$HOSTNAME', 'host=$HOSTNAME user=pgedge dbname=demo');
SELECT spock.repset_create('demo_replication_set');
_EOF_

IFS=',' read -r -a peer_names <<< "$PEER_NAMES"

for PEER_HOSTNAME in "${peer_names[@]}";
do
  while :
    do
      mapfile -t node_array < <(psql -A -t demo -h $PEER_HOSTNAME -c "SELECT node_name FROM spock.node;")
      for element in "${node_array[@]}";
      do
        if [[ "$element" == "$PEER_HOSTNAME" ]]; then
            break 2
        fi
      done
      sleep 1
      echo "Waiting for $PEER_HOSTNAME..."
    done
done

# spock.sub_create connects to the provider synchronously, and the peer
# restarts into its final foreground postgres at the end of its own setup,
# so a connection can land in the peer's stop/start window.  Retry until
# the peer is actually up.
create_sub() {
  local sub_name=$1
  local provider_dsn=$2

  for attempt in $(seq 1 60); do
    # A previous attempt may have already created the subscription
    if [ "$(psql -U admin -d demo -h /tmp -t -A -c "SELECT count(*) FROM spock.subscription WHERE sub_name = '$sub_name';")" = "1" ]; then
      return 0
    fi
    psql -U admin -d demo -h /tmp -v ON_ERROR_STOP=1 \
      -c "SELECT spock.sub_create('$sub_name', '$provider_dsn');" && return 0
    echo "Retrying sub_create $sub_name..."
    sleep 2
  done
  echo "Failed to create subscription $sub_name"
  return 1
}

create_sub sub_${peer_names[0]}$HOSTNAME "host=${peer_names[0]} port=5432 user=pgedge dbname=demo"
create_sub sub_${peer_names[1]}$HOSTNAME "host=${peer_names[1]} port=5432 user=pgedge dbname=demo"

psql -U admin -d demo -h /tmp -v ON_ERROR_STOP=1 <<_EOF_
SELECT spock.sub_add_repset('sub_${peer_names[0]}$HOSTNAME', 'demo_replication_set');
SELECT spock.sub_add_repset('sub_${peer_names[1]}$HOSTNAME', 'demo_replication_set');
_EOF_

# Build out of the bind-mounted source tree.  The mount may not be writable
# by this user (host ownership / SELinux labeling), so copy to a writable
# location first.
rm -rf /tmp/lolor-build
cp -a /home/pgedge/lolor /tmp/lolor-build
cd /tmp/lolor-build
# with_llvm=no skips JIT bitcode generation.  The platform expects a specific
# LLVM version (llvm-lto) that may not match the base image's installed LLVM,
# and JIT bitcode is irrelevant for these functional tests.
make USE_PGXS=1 with_llvm=no
make USE_PGXS=1 with_llvm=no install

psql -U admin -d demo -h /tmp -v ON_ERROR_STOP=1 <<_EOF_
create extension lolor;
alter system set lolor.node to ${HOSTNAME: -1};
_EOF_

psql -U admin -d demo -h /tmp -v ON_ERROR_STOP=1 <<_EOF_
SELECT spock.repset_add_table('demo_replication_set', 'lolor.pg_largeobject');
SELECT spock.repset_add_table('demo_replication_set', 'lolor.pg_largeobject_metadata');
_EOF_

pg_ctl -D "$PGDATA" -m fast -w stop

exec /home/pgedge/pgedge/pg${PG_VER}/bin/postgres -D "$PGDATA" 2>&1
