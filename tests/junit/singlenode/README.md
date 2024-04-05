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

### Run test suite

```
$ cd junit-tests
$ mvn test
$ mvn -Dtest=TestLargeObjectAPI test
$ mvn -Dtest=TestLargeObjectAPI#testInsert test
```
