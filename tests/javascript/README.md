# Test suite

These JavaScript tests are written to test pgEdge lolor extension.

These test cases relies on Large Object functionality provided
by `pg-large-object` package instead of calling lo_* methods directly.

## How to run Unit Tests

There is a need to install the following package on the
system i.e.

```
Debian
sudo apt install nodejs
sudo apt install npm

npm install --save-dev jest
npm install --save pg
npm install --save pg-large-object
npm install --save express
```

### Settings 

There is a need to configure GUC `lolor.node` in `postgresql.conf` e.g.
```
lolor.node = 1
```

Use `config.json` for test suite settings e.g. database connection, etc.

### Run test suite

```
$ npm test
```