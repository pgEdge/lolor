import unittest
import pg
from jproperties import Properties

conn = None
# test input data
data1 = b'0123456789abcdefghijklmnopqrstuvwxyz'

# Connect with PG
def initDB() :
    global conn
    configs = Properties()
    with open('test.properties', 'rb') as config_file:
        configs.load(config_file)

    try:
        conn = pg.DB(host=configs.get("host").data,
                     port=int(configs.get("port").data),
                     dbname=configs.get("dbname").data, # Database to be connected
                     user=configs.get("user").data,
                     passwd=configs.get("passwd").data)  # Database user password
        conn.query("CREATE EXTENSION IF NOT EXISTS lolor;")
    except pg.InternalError as ex:
        print(ex)
        print("Connect database failed")

# Close the connection
def cleanUP() :
    conn.close()

# Write large object and return oid
def writeLO(data) :
    lo1 = conn.locreate(pg.INV_READ | pg.INV_WRITE)
    oid = lo1.oid
    del lo1
    conn.query('begin')
    lo2 = conn.getlo(oid)
    lo2.open(pg.INV_WRITE)
    lo2.write(data)
    lo2.close()
    conn.commit()
    return oid

# Read large object and return data
def readLO(oid, size) :
    conn.query('begin')
    lo = conn.getlo(oid)
    lo.open(pg.INV_READ)
    data = lo.read(size)
    lo.close()
    conn.commit()
    return data

# Read large object, perform seek / write operation and return updated data
def seekLO(oid, data) :
    conn.query('begin')
    lo = conn.getlo(oid)
    lo.open(pg.INV_READ | pg.INV_WRITE)
    lo.seek(15, pg.SEEK_SET)
    lo.write(data)
    lo.close()
    conn.commit()
    return data

# Perform tell and write operations on large object 
def tellLO(oid, data) :
    conn.query('begin')
    lo = conn.getlo(oid)
    lo.open(pg.INV_READ | pg.INV_WRITE)
    pos1 = lo.tell()
    lo.write(data)
    pos2 = lo.tell()
    lo.close()
    conn.commit()
    return (pos1, pos2)

# Truncate large object
def truncateLO(oid, size) :
    conn.query('begin')
    result = conn.query("SELECT lo_open(" + str(oid) + ", x'60000'::int);")
    fd = result.onescalar()

    conn.query("select lo_truncate(" + str(fd) + "," + str(size) + ");")
    conn.commit()

class LOLORMethods(unittest.TestCase):
    # Basic data lo write and read test
    def test_LOReadWrite(self):
        oid = writeLO(data1)
        data = readLO(oid, len(data1))
        self.assertEqual(data1, data)

    # Basic lo seek test
    def test_LOSeek(self):
        expectedData = b'0123456789abcde<ADDEDDATA>qrstuvwxyz'
        oid = writeLO(data1)
        seekLO(oid, b'<ADDEDDATA>')
        data = readLO(oid, len(data1))
        self.assertEqual(expectedData, data)

    # Basic lo tell test
    def test_LOTell(self):
        expectedData = b'<ADDEDDATA>bcdefghijklmnopqrstuvwxyz'
        oid = writeLO(data1)
        pos1, pos2 = tellLO(oid, b'<ADDEDDATA>')
        data = readLO(oid, len(data1))
        self.assertEqual(expectedData, data)
        self.assertEqual(pos1, 0)
        self.assertEqual(pos2, 11)

    # Basic lo truncate test
    def test_LOTruncate(self):
        expectedData = b"0123456789"
        size = 10
        oid = writeLO(data1)
        truncateLO(oid, size)
        data = readLO(oid, len(data1))
        self.assertEqual(expectedData, data)

if __name__ == '__main__':
    initDB()
    unittest.main()
    cleanUP()