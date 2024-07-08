# lolor

lolor is a plugin in replacement for Postgres' Large Objects that makes them compatible with Logical Replication.

PostgreSQL supports large objects as related chunks in a pg_largeobject table, which stores binary and text data. Large objects provide stream-style access to user data stored in a special large-object structure in the catalog. However, replication of these catalog tables requires special handling of large objects. The lolor extension allows for the storage of large objects in non-catalog tables, aiding in replication of large objects.

It creates and manages large object related tables in lolor schema i.e.

```
lolor.pg_largeobject
lolor.pg_largeobject_metadata
```

The Large Objects feature in PostgreSQL allows for the storage of huge files within the database. Every large object is recognised by an OID that is assigned at the time of its creation. It stores objects in smaller segments within a separate system table. LOLOR also generates OIDs for large objects; however, they are distinct from those of native large objects.

## Requirements
LOLOR extension require PostgreSQL 16 or newer.

## Installation
lolor extension can be installed with `pgedge` cli (https://github.com/pgEdge/pgedge/blob/main/README.md).

Similarly, it can be utilised by compiling and installing from the source code, with the same guidelines as any other PostgreSQL extension constructed using PGXS.
Make sure that the PATH environment variable includes the directory where pg_config from the PostgreSQL installation is located i.e.

```
export PATH=/opt/pg16/bin:$PATH

# compile
make USE_PGXS=1
# install, might be requiring sudo for the installation step
make USE_PGXS=1 install
```

## Usage

This section describes basic usage of the lolor extension.

### Setup

`lolor.node` is required to be set before using the extension. It's value can be from 1 to 2^28, it will
help in generation of new large object OID i.e.

```
lolor.node = 1
```

You can also change the search_path to pick large object related tables from lolor schema e.g.

```
set search_path=lolor,"$user",public,pg_catalog
```

Next the lolor extension has to be installed on the database i.e.

```
CREATE EXTENSION LOLOR;
```
The existing methods from `pg_catalog.lo_*` are renamed to `pg_catalog.lo_*_orig`, and new versions of these methods are introduced.
During the extension's removal, the renamed `pg_catalog.lo_*_orig` functions are restored to their initial names.

While using `pgedge`, to enable replication of large objects, tables `pg_largeobject` and `pg_largeobject_metadata` are required to be added in replication set e.g.

```
./pgedge spock repset-add-table spock_replication_set 'lolor.pg_largeobject' lolor_db
./pgedge spock repset-add-table spock_replication_set 'lolor.pg_largeobject_metadata' lolor_db
```

### Example usage

```
-- Create a large object with no data, returns OID of new
lolor_db=# SELECT
        LO_CREAT (-1);
 lo_creat 
----------
  1100433
(1 row)

-- Get related stats
lolor_db=# SELECT * FROM
		lolor.PG_LARGEOBJECT_METADATA where oid = 1100433;
   oid   | lomowner | lomacl 
---------+----------+--------
 1100433 |       10 | 
(1 row)


-- Try to to create empty large object with OID 200000
lolor_db=# SELECT
        LO_CREATE (200001);
 lo_create 
-----------
    200001
(1 row)

-- Get related stats
lolor_db=# SELECT *
        FROM
        lolor.PG_LARGEOBJECT_METADATA where oid = 200001;
  oid   | lomowner | lomacl 
--------+----------+--------
 200001 |       10 | 
(1 row)

--  Try to import an operating system file as a large object
lolor_db=# SELECT
        LO_IMPORT ('/etc/os-release');
 lo_import 
-----------
   1100449
(1 row)

-- Get related info
lolor_db=# SELECT
        *
        FROM
        lolor.PG_LARGEOBJECT where loid = 1100449;
  loid   | pageno |                                                                                                                                                  
                                                                                                                         data                                        
                                                                                                                                                                     
                                                              
 1100449 |      0 | \x5052455454595f4e414d453d2244656269616e20474e552f4c696e75782031322028626f6f6b776f726d29220a4e414d453d2244656269616e20474e552f4c696e7578220a56455
253494f4e5f49443d223132220a56455253494f4e3d2231322028626f6f6b776f726d29220a56455253494f4e5f434f44454e414d453d626f6f6b776f726d0a49443d64656269616e0a484f4d455f55524c3d
2268747470733a2f2f7777772e64656269616e2e6f72672f220a535550504f52545f55524c3d2268747470733a2f2f7777772e64656269616e2e6f72672f737570706f7274220a4255475f5245504f52545f5
5524c3d2268747470733a2f2f627567732e64656269616e2e6f72672f220a
(1 row)

lolor_db=# SELECT
        LO_UNLINK (1100449);
 lo_unlink 
-----------
         1
(1 row)
```

## Limitations

- Native large object functionality cannot be used while using LOLOR extension
- Native large object migration to LOLOR feature is not available yet (TODO list)
- The statements `ALTER LARGE OBJECT`, `GRANT ON LARGE OBJECT`,
    `COMMENT ON LARGE OBJECT` AND `REVOKE ON LARGE OBJECT` don't have support
    yet (TODO list)
