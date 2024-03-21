package com.pgedge.lolor;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.AfterAll;
import static org.junit.jupiter.api.Assertions.assertArrayEquals;

import java.sql.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.Properties;

import org.postgresql.PGConnection;
import org.postgresql.largeobject.LargeObject;
import org.postgresql.largeobject.LargeObjectManager;

/*
* `TestLargeObjectAPI` class relies on Large Object classes available instead
*  of calling lo_* methods directly i.e.
*    LargeObjectManager
*    LargeObject
*
* */

//TODO: remove redundant code / refactor

public class TestLargeObjectAPI {
    public static Connection getPgconn() {
        return pgconn;
    }

    public static void setPgconn(Connection pgconn) {
        pgconn = pgconn;
    }

    private static Connection pgconn = null;
    private static Properties dbProps;
    private final static String dbPropsFile = "test.properties";
    private final String textFile1 = "data/text1.data";
    private final String textFile2 = "data/text2.data";
/*TODO:    private String binFile1 = "data/bin1.data";*/

    /*
     * inner class to store seek call parameters data
     * */
    class Seek {
        int offset;
        int whence;

        public Seek(int offset, int whence) {
            this.offset = offset;
            this.whence = whence;
        }

        public int getOffset() {
            return offset;
        }

        public void setOffset(int offset) {
            this.offset = offset;
        }

        public int getWhence() {
            return whence;
        }

        public void setWhence(int whence) {
            this.whence = whence;
        }
    }

    /*
     * Connect with PG
     * */
    public static void loadDBPropertiesFile() throws Exception {

        dbProps = new Properties();
        InputStream in = new FileInputStream(dbPropsFile);
        dbProps.load(in);
        in.close();
    }

   /*
    * Connect with PG
    * */
    public static void connectPG()
            throws Exception {
        try {
//            Class.forName(dbProps.getProperty("url"));
            pgconn = DriverManager.getConnection(dbProps.getProperty("url"), dbProps);
            pgconn.setAutoCommit(false);
        } catch (SQLException e) {
            throw new RuntimeException(e);
        }
    }

    /*
     * Close the connection
     * */
    public static void disconnectPG()
            throws Exception {
        try {
            /*TODO: check if already connection */
            pgconn.close();
        } catch (SQLException e) {
            throw new RuntimeException(e);
        }
    }

    /*
     * Close the connection
     * */
    public static void executeSQL(String sql)
            throws Exception {
        Statement stmt = null;
        try {
            stmt = pgconn.createStatement();
            stmt.executeUpdate(sql);
            stmt.close();
            pgconn.commit();
        } catch (SQLException e) {
            throw new RuntimeException(e);
        }
    }

    /*
     * Initialize database
     * */
    private static void initDB()
            throws Exception {
        String createExt = "CREATE EXTENSION IF NOT EXISTS lolor;";
        String dropExt = "DROP EXTENSION IF EXISTS lolor;";
        String dropTableSql = "DROP TABLE IF EXISTS pglotest_blobs CASCADE;";
        String createTableSql = "CREATE TABLE pglotest_blobs (\n" +
                "        fname           text PRIMARY KEY,\n" +
                "        blob            oid\n" +
                ");";
        if (dbProps.getOrDefault("with_lolor_extension", 1).equals("1")) {
            executeSQL(createExt);
        } else {
            executeSQL(dropExt);
        }
        executeSQL(dropTableSql);
        executeSQL(createTableSql);
    }

    /*
    * Initialise and make things ready
    * */
    @BeforeAll
    public static void init()
            throws Exception {
        loadDBPropertiesFile();
        connectPG();
        initDB();
    }

    /*
     * Clean up
     * */
    @AfterAll
    public static void cleanUp()
            throws Exception {
        String dropTableSql = "DROP TABLE IF EXISTS pglotest_blobs CASCADE;";
        executeSQL(dropTableSql);
        disconnectPG();
    }

    /*
    * Perform delete operation
    * It internally calls lo_unlink
    * */
    private boolean do_delete(String fname)
            throws Exception {
        LargeObjectManager lom;
        long oid;
        boolean dropped = false;

        // Delete the pglotest_blobs entry and get the Oid of the LO
        PreparedStatement ps = pgconn.prepareStatement("DELETE FROM pglotest_blobs WHERE fname = ? RETURNING blob");
        ps.setString(1, fname);
        ResultSet rs = ps.executeQuery();
        if (rs.next()) {
            // Delete the LO
            oid = rs.getLong(1);
            lom = ((PGConnection) pgconn).getLargeObjectAPI();
            lom.delete(oid);
            dropped = true;
        } else {
//            throw new Exception("Entry for " + fname + " not found");
        }
        return dropped;
    }

    /*
     * Perform insert operation
     * It internally calls lo_create, lo_open, lo_write, lo_close
     * */
    private byte[] do_insert(String fname)
            throws Exception {
        File file;
        FileInputStream fis;
        LargeObjectManager lom;
        long oid;
        LargeObject lo;
        byte[] buf = new byte[10];
        int n;
        ByteArrayOutputStream byteArrayOutStr = new ByteArrayOutputStream();

        // Open the input file as InputStream
        file = new File(fname);
        fis = new FileInputStream(file);

        // Create the LO
        lom = ((PGConnection) pgconn).getLargeObjectAPI();
        oid = lom.createLO();
        lo = lom.open(oid, LargeObjectManager.WRITE);
        while ((n = fis.read(buf, 0, buf.length)) > 0) {
            lo.write(buf, 0, n);
            byteArrayOutStr.write(buf, 0, n);
        }
        lo.close();

        // Create the entry in the pglotest_blobs table
        PreparedStatement ps = pgconn.prepareStatement("INSERT INTO pglotest_blobs VALUES (?, ?)");
        ps.setString(1, fname);
        ps.setLong(2, oid);
        ps.execute();
        ps.close();

        // Close the input file and commit the transaction
        fis.close();
        pgconn.commit();
        return byteArrayOutStr.toByteArray();
    }

    /*
     * Perform truncate operation
     * It internally calls lo_create, lo_open, lo_write, lo_truncate, lo_close
     * */
    private byte[] do_truncate(String fname, int size)
            throws Exception {
        File file;
        FileInputStream fis;
        LargeObjectManager lom;
        long oid;
        LargeObject lo;
        byte[] buf = new byte[10];
        int n;
        ByteArrayOutputStream byteArrayOutStr = new ByteArrayOutputStream();

        // Open the input file as InputStream
        file = new File(fname);
        fis = new FileInputStream(file);

        // Create the LO
        lom = ((PGConnection) pgconn).getLargeObjectAPI();
        oid = lom.createLO();
        lo = lom.open(oid, LargeObjectManager.WRITE);
        while ((n = fis.read(buf, 0, buf.length)) > 0) {
            lo.write(buf, 0, n);
            byteArrayOutStr.write(buf, 0, n);
        }
        lo.truncate(size);
        lo.close();

        // Create the entry in the pglotest_blobs table
        PreparedStatement ps = pgconn.prepareStatement("INSERT INTO pglotest_blobs VALUES (?, ?)");
        ps.setString(1, fname);
        ps.setLong(2, oid);
        ps.execute();
        ps.close();

        // Close the input file and commit the transaction
        fis.close();
        pgconn.commit();
        return byteArrayOutStr.toByteArray();
    }

    /*
     * Perform update operation
     * It internally calls lo_open, lo_write, lo_truncate, lo_close
     * */
    private byte[] do_update(String fname1, String fname2)
            throws Exception {
        File file;
        FileInputStream fis;
        LargeObjectManager lom;
        long oid;
        LargeObject lo;
        byte[] buf = new byte[10];
        int n;
        int len = 0;
        ByteArrayOutputStream byteArrayOutStr = new ByteArrayOutputStream();

        // Open the input file as InputStream
        file = new File(fname2);
        fis = new FileInputStream(file);

        // Get the Oid of the LO with that filename
        PreparedStatement ps = pgconn.prepareStatement("SELECT blob FROM pglotest_blobs WHERE fname = ?");
        ps.setString(1, fname1);
        ResultSet rs = ps.executeQuery();
        if (rs.next()) {
            // Update the LO
            oid = rs.getLong(1);
            lom = ((PGConnection) pgconn).getLargeObjectAPI();
            lo = lom.open(oid, LargeObjectManager.WRITE);
            while ((n = fis.read(buf, 0, buf.length)) > 0) {
                lo.write(buf, 0, n);
                byteArrayOutStr.write(buf, 0, n);
                len += n;
            }
            lo.truncate(len);
            lo.close();
        } else {
            throw new Exception("Entry for " + fname1 + " not found");
        }

        // Close the file and commit the transaction
        fis.close();
        pgconn.commit();
        return byteArrayOutStr.toByteArray();
    }

    /*
     * Perform read operation
     * It internally calls lo_open, loread, lo_seek, lo_close
     * */
    private byte[] do_select(String fname, Seek seek)
            throws Exception {
        LargeObjectManager lom;
        long oid;
        LargeObject lo;
        byte[] buf = new byte[10];
        int n;
        ByteArrayOutputStream byteArrayOutStr = new ByteArrayOutputStream();

        // Get the Oid of the LO with that filename
        PreparedStatement ps = pgconn.prepareStatement("SELECT blob FROM pglotest_blobs WHERE fname = ?");
        ps.setString(1, fname);
        ResultSet rs = ps.executeQuery();
        if (rs.next()) {
            // Open the LO and write its content to stdout
            oid = rs.getLong(1);
            lom = ((PGConnection) pgconn).getLargeObjectAPI();
            lo = lom.open(oid, LargeObjectManager.READ);
            if(seek != null) {
                lo.seek(seek.getOffset(), seek.getWhence());
            }
            while ((n = lo.read(buf, 0, buf.length)) > 0) {
                byteArrayOutStr.write(buf, 0, n);
            }
            lo.close();
        } else {
            throw new Exception("Entry for " + fname + " not found");
        }

        // Rollback the transaction
        pgconn.rollback();
        return byteArrayOutStr.toByteArray();
    }

    private byte[] do_select(String fname)
            throws Exception {
        return do_select(fname, null);
    }

    /*
    * Basic data insertion and retrieval test
    */
    @Test
    public void testInsert() throws Exception {
        /*delete */
        do_delete(textFile1);
        byte[] bufInput = do_insert(textFile1);
        byte[] bufOutput = do_select(textFile1);
        assertArrayEquals(bufInput, bufOutput);
    }

    /*
     * Basic data insertion and seek based retrieval test
     */
    @Test
    public void testSeek() throws Exception {
        Seek seek = new Seek(20, 0);
        String expectedValue = "Original version 1\n";
        do_delete(textFile1);
        do_insert(textFile1);
        byte[] bufOutput = do_select(textFile1, seek);
        assertArrayEquals(expectedValue.getBytes(StandardCharsets.UTF_8), bufOutput);
    }

    /*
     * Basic data insertion, truncate and retrieval test
     */
    @Test
    public void testTruncate() throws Exception {
        String expectedValue = "This is test file 1\n";
        do_delete(textFile1);
        do_truncate(textFile1, 20);
        byte[] bufOutput = do_select("data/text1.data");
        assertArrayEquals(expectedValue.getBytes(StandardCharsets.UTF_8), bufOutput);
    }

    /*
     * Basic data delete, insertion, update and retrieval test
     */
    @Test
    public void testUpdate() throws Exception {
        do_delete(textFile1);
        do_insert(textFile1);
        byte[] bufInput = do_update(textFile1, textFile2);
        byte[] bufOutput = do_select(textFile1);
        assertArrayEquals(bufInput, bufOutput);
    }
}
