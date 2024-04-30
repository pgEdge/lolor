# Test suite

These python tests are written to test pgEdge lolor extension.

`lolor_tests` relies on Large Object functionality provided
by `pygresql` module instead of calling lo_* methods directly.

## How to run Unit Tests

There is a need to download the python packages on the
system i.e.

```
pip3 install pygresql
pip3 install jproperties
```

### Settings 

There is a need to configure GUC `lolor.node` in `postgresql.conf` e.g.
```
lolor.node = 1
```

Use `test.properties` for test suite settings e.g. database connection.

### Run test suite

```
$ python3 lolor_tests.py
```
OR
```
$ python3 lolor_tests.py -v
```