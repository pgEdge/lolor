# lolor

[![CircleCI](https://dl.circleci.com/status-badge/img/gh/pgEdge/lolor/tree/main.svg?style=svg)](https://dl.circleci.com/status-badge/redirect/gh/pgEdge/lolor/tree/main)

lolor is an extension that makes Postgres' Large Objects compatible with Logical Replication.

PostgreSQL supports large objects as related chunks as described in the [pg_largeobject](https://www.postgresql.org/docs/17/catalog-pg-largeobject.html) table. Large objects provide stream-style access to user data stored in a special large-object structure in the catalog. Large objects stored in catalog tables require special handling during replication; the lolor extension allows for the storage of large objects in non-catalog tables, aiding in replication of large objects.

lolor creates and manages large object related tables in the lolor schema:

```
lolor.pg_largeobject
lolor.pg_largeobject_metadata
```

The Large Objects feature in PostgreSQL allows for the storage of huge files within the database. Each large object is recognised by an OID that is assigned at the time of its creation. lolor stores objects in smaller segments within a separate system table and generates associated OIDs for large objects that are distinct from those of native large objects.

## Requirements
Use of the lolor extension requires PostgreSQL 16 or newer.

## Installation

**Installing Snowflake with pgEdge binaries**

You can use the `pgedge` command line interface (CLI) to install the lolor extension (https://github.com/pgEdge/pgedge/blob/main/README.md).

To use pgEdge binaries to install lolor, go to [pgeEdge Github](https://github.com/pgEdge/pgedge) and install the pgEdge CLI:

`./pgedge install pg16 --start : install lolor`

**Installing Snowflake from source code**

You can also compile and install the extension from the source code, with the same guidelines as any other PostgreSQL extension constructed using PGXS.
Make sure that your PATH environment variable includes the directory where `pg_config` (under your PostgreSQL installation) is located.

```
export PATH=/opt/pg16/bin:$PATH

# compile
make USE_PGXS=1
# install, might be requiring sudo for the installation step
make USE_PGXS=1 install
```

After installing the lolor extension with either the pgEdge binary or from source code, connect to your Postgres database and create the extension with the command:

```
CREATE EXTENSION lolor;
```


### Configuration

You must set the `lolor.node` parameter before using the extension. The value can be from 1 to 2^28; the value is used to help in generation of new large object OID.

```
lolor.node = 1
```

You can also change the `search_path` to pick large object related tables from the `lolor` schema:

```
set search_path=lolor,"$user",public,pg_catalog
```

Any existing methods in `pg_catalog.lo_*` are renamed to `pg_catalog.lo_*_orig`, and new versions of these methods are introduced.
If you remove the extension, the renamed `pg_catalog.lo_*_orig` functions are restored to their initial names.

While using `pgedge` replication with large objects, you must have the tables `pg_largeobject` and `pg_largeobject_metadata` in your replication set; use 
the following commands to add the tables:

```
./pgedge spock repset-add-table spock_replication_set 'lolor.pg_largeobject' lolor_db
./pgedge spock repset-add-table spock_replication_set 'lolor.pg_largeobject_metadata' lolor_db
```

### Example usage

```
-- Create a large object with no data and return the oid:
lolor_db=# SELECT lo_creat (-1);
 lo_creat 
----------
  1100433
(1 row)

-- Querying the lolor schema for related stats:
lolor_db=# SELECT * FROM lolor.pg_largeobject_metadata where oid = 1100433:
   oid   | lomowner | lomacl 
---------+----------+--------
 1100433 |       10 | 
(1 row)

-- Creating an empty large object with oid 200000:
lolor_db=# SELECT lo_create (200000);
 lo_create 
-----------
    200000
(1 row)

-- Get related stats
lolor_db=# SELECT * FROM lolor.pg_largeobject_metadata where oid = 200001:
  oid   | lomowner | lomacl 
--------+----------+--------
 200001 |       10 | 
(1 row)

-- Import an operating system file as a large object:
lolor_db=# SELECT lo_import ('/etc/os-release');
 lo_import
-----------
   1100449
(1 row)

-- Return information about the large object:
lolor_db=# SELECT * FROM
        lolor.pg_largeobject where loid = 1100449;
  loid   | pageno | data                                                                  
 1100449 |      0 | \x5052455454595f4e414d453d2244656269616e20474e552f4c696e75782031322028626f6f6b776f726d29220a4e414d453d2244656269616e20474e552f4c696e7578220a56455
253494f4e5f49443d223132220a56455253494f4e3d2231322028626f6f6b776f726d29220a56455253494f4e5f434f44454e414d453d626f6f6b776f726d0a49443d64656269616e0a484f4d455f55524c3d
2268747470733a2f2f7777772e64656269616e2e6f72672f220a535550504f52545f55524c3d2268747470733a2f2f7777772e64656269616e2e6f72672f737570706f7274220a4255475f5245504f52545f5
5524c3d2268747470733a2f2f627567732e64656269616e2e6f72672f220a
(1 row)

-- Unlink a large object:
lolor_db=# SELECT lo_unlink (1100449);
 lo_unlink 
-----------
         1
(1 row)
```

## Manage large objects

`lolor` extension provide support for managing Large Objects similar to PostgreSQL native `lo` module. `spock.lo_manage` trigger function
can be used with trigger by attached tables that contain `LO` reference columns.

### Example usage

```
CREATE EXTENSION lolor;

-- example table and data
CREATE TABLE lotest(a INT PRIMARY KEY,
	b OID
);

INSERT INTO lotest
	VALUES (1, lo_import('/etc/os-release'));

-- check the large object oid
test_db=# SELECT * FROM lotest;
 a |   b    
---+--------
 1 | 412833
(1 row)

-- verify large object oid 
test_db=# SELECT * FROM lolor.pg_largeobject_metadata WHERE oid = 412833;
  oid   | lomowner | lomacl 
--------+----------+--------
 412833 |    16384 | 
(1 row)

-- manage table and cleanup to avoid orphen large object
CREATE TRIGGER t_lotest BEFORE UPDATE OR DELETE ON lotest
    FOR EACH ROW EXECUTE FUNCTION lolor.lo_manage(b);

-- delete table record related to large object
test_db=# DELETE FROM lotest WHERE a = 1;
NOTICE:  trigger t_lotest: (delete) removing large object oid 412833
DELETE 1

-- related large object also deleted with the table record
test_db=# SELECT * FROM lolor.pg_largeobject_metadata where oid = 412833;
 oid | lomowner | lomacl 
-----+----------+--------
(0 rows)
```

## Limitations

- Native large object functionality cannot be used while you are using the lolor extension.
- Native large object migration to the lolor feature is not available yet.
- lolor does not support the following statements: `ALTER LARGE OBJECT`, `GRANT ON LARGE OBJECT`, `COMMENT ON LARGE OBJECT`, and `REVOKE ON LARGE OBJECT`.
