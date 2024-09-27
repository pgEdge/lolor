# lolor

Large Objects for Logical Replication.

PostgreSQL's large objects live in the `pg_largeobject` and
`pg_largeobject_metadata` system catalogs.  Logical decoding ignores system
catalogs, and each node allocates large object OIDs from its own counter, so
large objects neither replicate nor stay unique across nodes.

lolor, together with a small core patch, fixes both.  The native `lo_*`
functions, the libpq large object API and `pg_dump` keep working unchanged: the
data stays in the native catalogs.

## How it works

The **core patch** (`patches/`) does three things:

- `RelationIsLogicallyLogged()` treats the two large object catalogs like user
  tables once they have a replica identity.  Catalogs are created without one
  (`REPLICA IDENTITY NOTHING`), so a server without lolor behaves exactly like
  an unpatched one.
- It adds `LargeObjectNewOid_hook`, consulted when a large object is created
  without an explicit OID.
- It fixes `heap_delete()` and `ExecSimpleRelationUpdate()` for catalog
  relations that are logically logged.

The **extension** does the rest:

- Its OID allocator keeps the OIDs of different nodes apart by putting the
  node id (`lolor.node`) in the low 4 bits.
- `CREATE EXTENSION lolor` gives both catalogs `REPLICA IDENTITY DEFAULT` (they
  have primary keys), which switches logging on.  `DROP EXTENSION lolor`
  switches it off again.  Large objects stay where they are.

## Requirements

- A PostgreSQL server built with the patch from `patches/<version>/`.
  Currently only PostgreSQL 18 is provided.
- `shared_preload_libraries = 'lolor'`, so that the hook is active in every
  backend.  `CREATE EXTENSION` fails otherwise.
- `lolor.node`, a value from 1 to 15, unique for every node of the cluster, set
  in `postgresql.conf`.  It cannot change while the server runs.
- `wal_level = logical`.

## Installation

```
# build and install the patched server first, then:
export PATH=/path/to/patched/bin:$PATH
make USE_PGXS=1
make USE_PGXS=1 install
```

In `postgresql.conf` of every node:

```
shared_preload_libraries = 'lolor'
lolor.node = 1
wal_level = logical
```

then, in every database that uses large objects:

```
CREATE EXTENSION lolor;
```

## Replicating large objects

With Spock, add the two catalogs to a replication set on the nodes that
publish large objects:

```
SELECT spock.repset_add_table('default', 'pg_catalog.pg_largeobject');
SELECT spock.repset_add_table('default', 'pg_catalog.pg_largeobject_metadata');
```

`lolor.replication_enabled()` tells whether the server logs changes to the
catalogs.  `lolor.set_replica_identity(true)` switches that on again where the
setting got lost: `pg_upgrade` creates extensions without running the install
script, so call it after an upgrade.

## Limitations

- The owner and ACL of a large object are stored as role OIDs, which differ
  from node to node.  On another node, a replicated large object's owner may be
  a different role or none at all.  Keep the role OIDs identical on all nodes, or
  avoid per-role large object ownership, until this is addressed.
- Comments and security labels on large objects are not replicated.
- Native publications (`CREATE PUBLICATION`) refuse system catalogs and are not
  supported.
- At most 15 nodes (`lolor.node` is 4 bits).

## Tests

`sql/lolor.sql` needs a patched server that runs with the settings above, plus
`test_decoding`:

```
make USE_PGXS=1 installcheck
```
