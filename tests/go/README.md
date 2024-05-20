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

### Run test suite

```
$ go test -v
```