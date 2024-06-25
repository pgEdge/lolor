# Test suite

These JUnit tests are written to test pgEdge lolor extension.
There are 20 lo_* methods that required to be tests i.e.

```
lo_close
lo_creat
lo_create
lo_export
lo_from_bytea
lo_get
lo_get_fragment
lo_import
lo_import_with_oid
lo_lseek
lo_lseek64
lo_open
lo_put
lo_tell
lo_tell64
lo_truncate
lo_truncate64
lo_unlink
loread
lowrite
```

`TestLargeObjectAPI` class relies on Large Object classes available instead of
calling lo_* methods directly.

## Maven - How to run Unit Test

There is a need to install `maven` on the system e.g.

*Debian*
sudo apt install maven

*Redhat (Rocky/RHEL)*

Download and install latest maven package from https://maven.apache.org/download.cgi

### Settings 

There is a need to configure GUC `lolor.node` in `postgresql.conf` e.g.
```
lolor.node = 1
```

Use `test.properties` for test suite settings e.g. database connection, etc.

To enable replication of `lolor` large objects, there is a need to add tables
`lolor.pg_largeobject` and `lolor.pg_largeobject_metadata` to `spock`
replication set e.g.

Run the following commands to create replication set i.e.
```
# All Nodes
./pgedge spock repset-create lolor_tables_rs test_db

# Node1
./pgedge spock sub-add-repset sub_n1n2 lolor_tables_rs test_db
./pgedge spock sub-add-repset sub_n1n3 lolor_tables_rs test_db

# Node2
./pgedge spock sub-add-repset sub_n2n1 lolor_tables_rs test_db
./pgedge spock sub-add-repset sub_n2n3 lolor_tables_rs test_db

# Node3
./pgedge spock sub-add-repset sub_n3n1 lolor_tables_rs test_db
./pgedge spock sub-add-repset sub_n3n2 lolor_tables_rs test_db

# All Nodes
# psql -d test_db
CREATE EXTENSION lolor;
./pgedge spock repset-add-table lolor_tables_rs 'lolor.pg_largeobject' test_db
./pgedge spock repset-add-table lolor_tables_rs 'lolor.pg_largeobject_metadata' test_db
```

### Run test suite

```
$ cd junit-tests
$ mvn test
$ mvn -Dtest=TestLOMethods test
$ mvn -Dtest=TestLOMethods#t1 test
```
