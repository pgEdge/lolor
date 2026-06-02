#!/bin/bash
set -e

cd /home/pgedge/pgedge
. pg${PG_VER}/pg${PG_VER}.env
echo 'export LD_LIBRARY_PATH=/home/pgedge/pgedge/pg${PG_VER}/lib:$LD_LIBRARY_PATH' >> /home/pgedge/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/lib64:$LD_LIBRARY_PATH' >> /home/pgedge/.bashrc
echo 'export PATH=/home/pgedge/pgedge/pg${PG_VER}/bin:$PATH' >> /home/pgedge/.bashrc
. /home/pgedge/.bashrc
sudo ldconfig

./pgedge start

while ! pg_isready -h /tmp; do
  echo "Waiting for PostgreSQL to become ready..."
  sleep 1
done

echo "==========Creating tables and repsets=========="
./pgedge spock node-create $HOSTNAME "host=$HOSTNAME user=pgedge dbname=demo" demo
./pgedge spock repset-create demo_replication_set demo

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

./pgedge spock sub-create sub_${peer_names[0]}$HOSTNAME   "host=${peer_names[0]} port=5432 user=pgedge dbname=demo" demo
./pgedge spock sub-create sub_${peer_names[1]}$HOSTNAME   "host=${peer_names[1]} port=5432 user=pgedge dbname=demo" demo
./pgedge spock sub-add-repset sub_${peer_names[0]}$HOSTNAME demo_replication_set demo
./pgedge spock sub-add-repset sub_${peer_names[1]}$HOSTNAME demo_replication_set demo

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

psql -U admin -d demo -h /tmp <<_EOF_
drop extension lolor;
create extension lolor; 
alter system set lolor.node to ${HOSTNAME: -1};
_EOF_

cd /home/pgedge/pgedge
./pgedge spock repset-add-table demo_replication_set 'lolor.pg_largeobject' demo
./pgedge spock repset-add-table demo_replication_set 'lolor.pg_largeobject_metadata' demo

./pgedge stop

/home/pgedge/pgedge/pg${PG_VER}/bin/postgres -D /home/pgedge/pgedge/data/pg${PG_VER} 2>&1
