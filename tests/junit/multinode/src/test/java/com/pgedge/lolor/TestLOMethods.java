package com.pgedge.lolor;

import static com.pgedge.lolor.Utility.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.AfterAll;
import org.postgresql.util.PSQLException;

import static org.junit.jupiter.api.Assertions.assertEquals;

/*
* `TestLOMethods` class relies on calling LO_* methods directly to assess the
*  large object functionality i.e.
*    lo_close
*    lo_creat
*    lo_create
*    lo_export
*    lo_from_bytea
*    lo_get
*    lo_get_fragment
*    lo_import
*    lo_import_with_oid
*    lo_lseek
*    lo_lseek64
*    lo_open
*    lo_put
*    lo_tell
*    lo_tell64
*    lo_truncate
*    lo_truncate64
*    lo_unlink
*    loread
*    lowrite
*
*  Node: These tests can be written as structured block (anonymous block) but the purpose of each individual lo_*
*  method call is to verify the return values
* */

//TODO: remove un necessory expected out files
//TODO: better expected out verification mechenism
//TODO: probably remove singlenode test suite as multinode test harness can work for single node as well?
//TODO: currently 3 nodes hard coded, there should be a feature to allow specify connections info (URL etc) for multiple nodes configuration in properties file
//TODO: remove redundant code / refactor
public class TestLOMethods {
    // data files that are required to be used with lo_* methods like lo_import etc.
    static String datafile1_local = System.getProperty("user.dir") + "/data/text1.data";
    static String datafile1_server = "/tmp/text1.data";

    /*
    * Initialise and make things ready
    * */
    @BeforeAll
    public static void init()
            throws Exception {
        loadDBPropertiesFile();
        connectPG();
        initDB();
        // Copy test data files to the server machine
        copyFileToServer(datafile1_local, datafile1_server);
    }

    /*
     * Clean up
     * */
    @AfterAll
    public static void cleanUp()
            throws Exception {
        disconnectPG();
    }

    /*
     * Test lo_creat method
     */
    public String t1_a_lo_creat()
            throws Exception {
        // TODO: probably pick SQL from file
        QueryResult result = executeSQL(0, "select lo_creat(0);");
        String loid = getLine(result.getResult(), 1);
        String expected = readFile("expected/t1_a_lo_creat");
        assertEquals(expected.replace("<xxxx1>", loid), result.getResult());
        return loid;
    }

    /*
     * Test lo_unlink method
     */
    public void t1_d_lo_unlink(String loid)
            throws Exception {
        QueryResult result = executeSQL(0, "select lo_unlink(" + loid + ");");
        String expected = readFile("expected/t1_d_lo_unlink");
        assertEquals(expected, result.getResult());
    }

    /*
     * Basic lo_create() test
     */
    public String t2_a_lo_create()
            throws Exception {
        // TODO: probably pick SQL from file
        QueryResult result = executeSQL(0, "select lo_create(0);");
        String loid = getLine(result.getResult(), 1);
        String expected = readFile("expected/t2_a_lo_create");
        assertEquals(expected.replace("<xxxx1>", loid), result.getResult());
        return loid;
    }

    /*
     * Test lo_unlink
     */
    public void t2_d_lo_unlink(String loid)
            throws Exception {
        QueryResult result = executeSQL(0, "select lo_unlink(" + loid + ");");
        String expected = readFile("expected/t2_d_lo_unlink");
        assertEquals(expected, result.getResult());
    }

    /*
     * Test lo_import
     */
    public String t3_a_lo_import()
            throws Exception {
        // TODO: probably pick SQL from file
        QueryResult result = executeSQL(0, "select lo_import('" + datafile1_server + "');");
        //TODO: conversion required ?
        String loid = getLine(result.getResult(), 1);
        String expected = readFile("expected/t3_a_lo_import");
        assertEquals(expected.replace("<xxxx1>", loid), result.getResult());
        return loid;
    }

    /*
     * Test lo_export
     */
    public void t3_b_lo_export(String loid)
            throws Exception {
        // input file path
        String fname_in = datafile1_local;
        // exported file path
        String fname_out = "/tmp/text1_modified.data";
        waitForSync();
        QueryResult result = executeSQL("select lo_export(" + loid + ", '" + fname_out + "');");
        String expected = readFile("expected/t3_b_lo_export");
        // read input and exported files
        String input = readFile(fname_in);
        copyFileToLocal(fname_out, fname_out);
        String exported = readFile(fname_out);
        // verify
        assertEquals(expected.replace("<xxxx1>", loid), result.getResult());
        assertEquals(input, exported);
    }

    /*
     * Test pg_largeobject
     */
    public void t3_d_pg_largeobject(String loid)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject where loid = " + loid + ";");
        String expected = readFile("expected/t3_d_pg_largeobject");
        // verify
        assertEquals(expected.replace("<xxxx1>", loid), result.getResult());
    }

    /*
     * Test lo_unlink
     */
    public void t3_e_lo_unlink(String loid)
            throws Exception {
        QueryResult result = executeSQL(0, "select lo_unlink(" + loid + ");");
        String expected = readFile("expected/t3_e_lo_unlink");
        assertEquals(expected, result.getResult());
    }

    /*
     * Test lo_import
     */
    public String t4_a_lo_import()
            throws Exception {
        // TODO: probably pick SQL from file
        QueryResult result = executeSQL(0, "select lo_import('" + datafile1_server + "');");
        // get large object oid
        String loid = getLine(result.getResult(), 1);
        String expected = readFile("expected/t4_a_lo_import");
        // verify
        assertEquals(expected.replace("<xxxx1>", loid), result.getResult());
        return loid;
    }

    /*
     * Test lo_open
     */
    public String t4_b_lo_open(String loid)
            throws Exception {
        QueryResult result = executeSQL(0, "SELECT lo_open(" + loid + ", x'60000'::int);", false);
        // get large object file descriptor
        String fd = getLine(result.getResult(), 1);
        String expected = readFile("expected/t4_b_lo_open");
        // verify
        assertEquals(expected.replace("<xxxx1>", fd), result.getResult());
        return fd;
    }

    /*
     * Test lo_lseek
     */
    public String t4_c_lo_lseek(String fd)
            throws Exception {
        QueryResult result = executeSQL(0, "SELECT lo_lseek(" + fd + ", 13, 0);", false);
        String expected = readFile("expected/t4_c_lo_lseek");
        // verify
        assertEquals(expected, result.getResult());
        return fd;
    }

    /*
     * Test lowrite
     */
    public String t4_d_lowrite(String fd)
            throws Exception {
        QueryResult result = executeSQL(0, "SELECT lowrite(" + fd + ", 'data'::bytea);", false);
        String expected = readFile("expected/t4_d_lowrite");
        // verify
        assertEquals(expected, result.getResult());
        return fd;
    }

    /*
     * Test lo_tell
     */
    public String t4_e_lo_tell(String fd)
            throws Exception {
        QueryResult result = executeSQL(0, "SELECT lo_tell(" + fd + ");", false);
        String expected = readFile("expected/t4_e_lo_tell");
        // verify
        assertEquals(expected, result.getResult());
        return fd;
    }

    /*
     * Test lo_lseek64
     */
    public String t4_f_lo_lseek64(String fd)
            throws Exception {
        QueryResult result = executeSQL(0, "SELECT lo_lseek(" + fd + ", 5, 0);", false);
        String expected = readFile("expected/t4_f_lo_lseek64");
        // verify
        assertEquals(expected, result.getResult());
        return fd;
    }

    /*
     * Test lo_tell64
     */
    public String t4_g_lo_tell64(String fd)
            throws Exception {
        QueryResult result = executeSQL(0, "SELECT lo_tell64(" + fd + ");", false);
        String expected = readFile("expected/t4_d_lo_tell64");
        // verify
        assertEquals(expected, result.getResult());
        return fd;
    }

    /*
     * Test lo_truncate method
     */
    public void t4_h_lo_truncate(String fd, int size)
            throws Exception {
        QueryResult result = executeSQL(0, "select lo_truncate(" + fd + "," + size + ");", false);
        String expected = readFile("expected/t4_h_lo_truncate");
        assertEquals(expected, result.getResult());
    }

    /*
     * Test lo_close
     */
    public String t4_i_lo_close(String fd)
            throws Exception {
        QueryResult result = executeSQL(0, "SELECT lo_close(" + fd + ");");
        String expected = readFile("expected/t4_i_lo_close");
        assertEquals(expected, result.getResult());
        return fd;
    }

    /*
     * Test lo_unlink
     */
    public void t4_l_lo_unlink(String loid)
            throws Exception {
        QueryResult result = executeSQL(0, "select lo_unlink(" + loid + ");");
        String expected = readFile("expected/t4_l_lo_unlink");
        // verify
        assertEquals(expected, result.getResult());
    }

    /*
     * Test lo_from_bytea
     */
    public String t5_a_lo_from_bytea()
            throws Exception {
        // TODO: probably pick SQL from file
        QueryResult result = executeSQL(0, "SELECT lo_from_bytea(0, '0123456789abcdefghijklmnopqrstuvwxyz'::bytea);");
        // get large object oid
        String loid = getLine(result.getResult(), 1);
        String expected = readFile("expected/t5_a_lo_from_bytea");
        // verify
        assertEquals(expected.replace("<xxxx1>", loid), result.getResult());
        return loid;
    }

    /*
     * Test lo_from_bytea
     */
    public void t5_d_lo_from_bytea(String loid)
            throws Exception {
        // TODO: probably pick SQL from file
        String exceptionText = "";
        try {
            QueryResult result = executeSQL(0, "SELECT lo_from_bytea(" + loid + ", 'Updated text 123'::bytea);");
        } catch (RuntimeException exception) {
            if(exception.getCause().getClass().getName().compareTo("org.postgresql.util.PSQLException") == 0 &&
                    ((PSQLException)exception.getCause()).getSQLState().compareTo("23505") == 0) {
                exceptionText = ((PSQLException)exception.getCause()).toString();
            }
        }
        String expected = readFile("expected/t5_d_lo_from_bytea");
        // verify
        assertEquals(expected.replace("<xxxx1>", loid), exceptionText);
    }

    /*
     * Test lo_put
     */
    public String t5_f_lo_put(String loid)
            throws Exception {
        // TODO: probably pick SQL from file
        QueryResult result = executeSQL(0, "SELECT lo_put(" + loid + ", 4, 'XYZ'::bytea);");
        String expected = readFile("expected/t5_f_lo_put");
        // verify
        assertEquals(expected, result.getResult());
        return loid;
    }

    /*
     * Query lo_get
     */
    public static void t5_h_lo_get(String loid)
            throws Exception {
        QueryResult result = executeSQL("select convert_from(lo_get(" + loid + ", 4, 3), 'utf-8');", true);
        String expected = readFile("expected/t5_h_lo_get");
        assertEquals(expected, result.getResult());
    }

    /*
     * Basic test that covers i.e.
     *  lo_creat
     *  lo_unlink
     *  pg_largeobject_metadata catalog table
     *  pg_largeobject catalog table
     */
    @Test
    public void t1()
            throws Exception {
        String loid = t1_a_lo_creat();
        // verify
        pg_largeobject_metadata(loid, "expected/t1_b_pg_largeobject_metadata");
        pg_largeobject(loid, "expected/t1_c_pg_largeobject");
        // clean up
        t1_d_lo_unlink(loid);
        // verify
        pg_largeobject_metadata(loid, "expected/t1_e_pg_largeobject_metadata");
        //TODO: check pg_largeobject as well?
    }

    /*
     * Basic test that covers i.e.
     *  lo_create
     *  lo_unlink
     *  pg_largeobject_metadata catalog table
     *  pg_largeobject catalog table
     */
    @Test
    public void t2()
            throws Exception {
        String loid = t2_a_lo_create();
        // verify
        pg_largeobject_metadata(loid, "expected/t1_b_pg_largeobject_metadata");
        pg_largeobject(loid, "expected/t2_c_pg_largeobject");
        // clean up
        t2_d_lo_unlink(loid);
        // verify
        pg_largeobject_metadata(loid, "expected/t2_e_pg_largeobject_metadata");
    }

    /*
     * Basic test that covers i.e.
     *  lo_import
     *  lo_export
     *  lo_unlink
     *  pg_largeobject_metadata catalog table
     *  pg_largeobject catalog table
     */
    @Test
    public void t3()
            throws Exception {
        String loid = t3_a_lo_import();
        // verify
        executeSQL("set bytea_output = 'escape';");
        pg_largeobject_metadata(loid, "expected/t3_c_pg_largeobject_metadata");
        t3_d_pg_largeobject(loid);
        t3_b_lo_export(loid);
        // clean up
        t3_e_lo_unlink(loid);
        // verify
        pg_largeobject_metadata(loid, "expected/t3_f_pg_largeobject_metadata");
    }

    /*
     * Basic test that covers i.e.
     *  lo_import
     *  lo_open
     *  lo_seek
     *  lo_seek64
     *  lowrite
     *  lo_tell
     *  lo_tell64
     *  lo_unlink
     *  pg_largeobject_metadata catalog table
     *  pg_largeobject catalog table
     */
    @Test
    public void t4()
            throws Exception {
        String loid = t4_a_lo_import();
        // open lo
        String fd = t4_b_lo_open(loid);
        // move cursor
        t4_c_lo_lseek(fd);
        // write
        t4_d_lowrite(fd);
        // check cursor location
        t4_e_lo_tell(fd);
        // move cursor
        t4_f_lo_lseek64(fd);
        // check cursor location
        t4_g_lo_tell64(fd);
        // try truncate
        t4_h_lo_truncate(fd, 28);
        lo_truncate64(fd, 27);
        // close descriptor
        t4_i_lo_close(fd);
        // verify
        executeSQL("set bytea_output = 'escape';");
        pg_largeobject_metadata(loid, "expected/t4_j_pg_largeobject_metadata");
        pg_largeobject(loid, "expected/t4_k_pg_largeobject");
        // clean up
        t4_l_lo_unlink(loid);
        // verify
        pg_largeobject_metadata(loid, "expected/t4_m_pg_largeobject_metadata");
    }

    /*
     * Basic test that covers i.e.
     *  lo_from_bytea
     *  lo_get
     *  lo_put
     *  lo_unlink
     *  pg_largeobject_metadata catalog table
     *  pg_largeobject catalog table
     */
    @Test
    public void t5()
            throws Exception {
        String loid = t5_a_lo_from_bytea();
        // verify
        pg_largeobject_metadata(loid, true);
        pg_largeobject(loid, true);
        // try to create new large object with same oid
        t5_d_lo_from_bytea(loid);
        // try lo_get
        lo_get(loid, true);
        // try lo_put
        t5_f_lo_put(loid);
        // verify
        pg_largeobject(loid, "expected/t5_g_pg_largeobject");
        // try lo_get
        t5_h_lo_get(loid);
        // clean up
        lo_unlink(loid);
        // verify
        pg_largeobject_metadata(loid, false);
    }
}
