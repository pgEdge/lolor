# Test suite

These go tests are written to test pgEdge lolor extension.

`lolor_tests` package relies on Large Object functionality provided
by `github.com/jackc/pgx/v5` module instead of calling lo_* methods directly.

## How to run Unit Tests

There is a need to download the go package `github.com/jackc/pgx/v5` on the
system i.e.

```
go get github.com/jackc/pgx/v5
go get github.com/magiconair/properties
```

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
$ go test -v
```
