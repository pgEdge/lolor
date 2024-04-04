# lolor

## Large Object LOgical Replication

A plugin in replacement for Postgres' Large Objects that makes them compatible with Logical Replication.

## GUCs

`lolor.node` is required to be set before using the extension. It's value can be from 1 to 2^28, it will
help in generation of new large object OID.