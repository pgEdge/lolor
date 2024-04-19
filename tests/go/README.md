# Test suite

These go tests are written to test pgEdge lolor extension.

`lolor_tests` package relies on Large Object functionality provided
by `github.com/jackc/pgx/v5` module instead of calling lo_* methods directly.

## How to run Unit Tests

There is a need to download the go package `github.com/jackc/pgx/v5` on the
system i.e.

```
go get github.com/jackc/pgx/v5
```

### Settings 

There is a need to configure GUC `lolor.node` in `postgresql.conf` e.g.
```
lolor.node = 1
```

Set enviornment variable `DATABASE_URL` for database connection string e.g.

```
# BASH shell
export DATABASE_URL="postgres://asif:password@localhost:5432/postgres"
```

### Run test suite

```
$ go test -v
```