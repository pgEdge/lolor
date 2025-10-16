# Using lolor

The following command examples demonstrate using lolor:

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