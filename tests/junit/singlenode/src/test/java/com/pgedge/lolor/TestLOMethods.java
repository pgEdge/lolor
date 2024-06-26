package com.pgedge.lolor;

import static com.pgedge.lolor.Utility.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.AfterAll;
import org.postgresql.util.PSQLException;

import java.sql.SQLException;

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

//TODO: remove redundant code / refactor
public class TestLOMethods {
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
        disconnectPG();
    }

    /*
     * Test lo_creat method
     */
    public int t1_a_lo_creat()
            throws Exception {
        // TODO: probably pick SQL from file
        QueryResult result = executeSQL("select lo_creat(0);");
        int loid = Integer.parseInt(getLine(result.getResult(), 1));
        String expected = readFile("expected/t1_a_lo_creat");
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
        return loid;
    }

    /*
     * Test pg_largeobject_metadata table
     */
    public void t1_b_pg_largeobject_metadata(int loid)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject_metadata where oid = " + loid + ";");
        String expected = readFile("expected/t1_b_pg_largeobject_metadata");
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Test pg_largeobject table
     */
    public void t1_c_pg_largeobject(int loid)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject where loid = " + loid + ";");
        String expected = readFile("expected/t1_c_pg_largeobject");
        assertEquals(expected, result.getResult());
    }

    /*
     * Test lo_unlink method
     */
    public void t1_d_lo_unlink(int loid)
            throws Exception {
        QueryResult result = executeSQL("select lo_unlink(" + loid + ");");
        String expected = readFile("expected/t1_d_lo_unlink");
        assertEquals(expected, result.getResult());
    }

    /*
     * Test pg_largeobject_metadata table
     */
    public void t1_e_pg_largeobject_metadata(int loid)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject_metadata where oid = " + loid + ";");
        String expected = readFile("expected/t1_e_pg_largeobject_metadata");
        assertEquals(expected, result.getResult());
    }

    /*
     * Basic lo_create() test
     */
    public int t2_a_lo_create()
            throws Exception {
        // TODO: probably pick SQL from file
        QueryResult result = executeSQL("select lo_create(0);");
        int loid = Integer.parseInt(getLine(result.getResult(), 1));
        String expected = readFile("expected/t2_a_lo_create");
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
        return loid;
    }

    /*
     * Test pg_largeobject_metadata table
     */
    public void t2_b_pg_largeobject_metadata(int loid)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject_metadata where oid = " + loid + ";");
        String expected = readFile("expected/t2_b_pg_largeobject_metadata");
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Test pg_largeobject table
     */
    public void t2_c_pg_largeobject(int loid)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject where loid = " + loid + ";");
        String expected = readFile("expected/t2_c_pg_largeobject");
        assertEquals(expected, result.getResult());
    }

    /*
     * Test lo_unlink
     */
    public void t2_d_lo_unlink(int loid)
            throws Exception {
        QueryResult result = executeSQL("select lo_unlink(" + loid + ");");
        String expected = readFile("expected/t2_d_lo_unlink");
        assertEquals(expected, result.getResult());
    }

    /*
     * Test pg_largeobject_metadata
     */
    public void t2_e_pg_largeobject_metadata(int loid)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject_metadata where oid = " + loid + ";");
        String expected = readFile("expected/t2_e_pg_largeobject_metadata");
        assertEquals(expected, result.getResult());
    }

    /*
     * Test lo_import
     */
    public int t3_a_lo_import()
            throws Exception {
        // TODO: probably pick SQL from file
        String fname = System.getProperty("user.dir") + "/data/text1.data";
        QueryResult result = executeSQL("select lo_import('" + fname + "');");
        //TODO: conversion required ?
        int loid = Integer.parseInt(getLine(result.getResult(), 1));
        String expected = readFile("expected/t3_a_lo_import");
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
        return loid;
    }

    /*
     * Test lo_export
     */
    public void t3_b_lo_export(int loid)
            throws Exception {
        // input file path
        String fname_in = System.getProperty("user.dir") + "/data/text1.data";
        // exported file path
        String fname_out = "/tmp/text1_modified.data";
        QueryResult result = executeSQL("select lo_export(" + loid + ", '" + fname_out + "');");
        String expected = readFile("expected/t3_b_lo_export");
        // read input and exported files
        String input = readFile(fname_in);
        String exported = readFile(fname_out);
        // verify
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
        assertEquals(input, exported);
    }

    /*
     * Test pg_largeobject_metadata
     */
    public void t3_c_pg_largeobject_metadata(int loid)
            throws Exception {
        executeSQL("set bytea_output = 'escape';");
        QueryResult result = executeSQL("select * from pg_largeobject_metadata where oid = " + loid + ";");
        String expected = readFile("expected/t3_c_pg_largeobject_metadata");
        // verify
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Test pg_largeobject
     */
    public void t3_d_pg_largeobject(int loid)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject where loid = " + loid + ";");
        String expected = readFile("expected/t3_d_pg_largeobject");
        // verify
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Test lo_unlink
     */
    public void t3_e_lo_unlink(int loid)
            throws Exception {
        QueryResult result = executeSQL("select lo_unlink(" + loid + ");");
        String expected = readFile("expected/t3_e_lo_unlink");
        assertEquals(expected, result.getResult());
    }

    /*
     * Test pg_largeobject_metadata
     */
    public void t3_f_pg_largeobject_metadata(int loid)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject_metadata where oid = " + loid + ";");
        String expected = readFile("expected/t3_f_pg_largeobject_metadata");
        assertEquals(expected, result.getResult());
    }

    /*
     * Test lo_import
     */
    public int t4_a_lo_import()
            throws Exception {
        // TODO: probably pick SQL from file
        String fname = System.getProperty("user.dir") + "/data/text1.data";
        QueryResult result = executeSQL("select lo_import('" + fname + "');");
        // get large object oid
        int loid = Integer.parseInt(getLine(result.getResult(), 1));
        String expected = readFile("expected/t4_a_lo_import");
        // verify
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
        return loid;
    }

    /*
     * Test lo_open
     */
    public int t4_b_lo_open(int loid)
            throws Exception {
        QueryResult result = executeSQL("SELECT lo_open(" + loid + ", x'60000'::int);", false);
        // get large object file descriptor
        int fd = Integer.parseInt(getLine(result.getResult(), 1));
        String expected = readFile("expected/t4_b_lo_open");
        // verify
        assertEquals(expected.replace("<xxxx1>", String.valueOf(fd)), result.getResult());
        return fd;
    }

    /*
     * Test lo_lseek
     */
    public int t4_c_lo_lseek(int fd)
            throws Exception {
        QueryResult result = executeSQL("SELECT lo_lseek(" + fd + ", 13, 0);", false);
        String expected = readFile("expected/t4_c_lo_lseek");
        // verify
        assertEquals(expected, result.getResult());
        return fd;
    }

    /*
     * Test lowrite
     */
    public int t4_d_lowrite(int fd)
            throws Exception {
        QueryResult result = executeSQL("SELECT lowrite(" + fd + ", 'data'::bytea);", false);
        String expected = readFile("expected/t4_d_lowrite");
        // verify
        assertEquals(expected, result.getResult());
        return fd;
    }

    /*
     * Test lo_tell
     */
    public int t4_e_lo_tell(int fd)
            throws Exception {
        QueryResult result = executeSQL("SELECT lo_tell(" + fd + ");", false);
        String expected = readFile("expected/t4_e_lo_tell");
        // verify
        assertEquals(expected, result.getResult());
        return fd;
    }

    /*
     * Test lo_lseek64
     */
    public int t4_f_lo_lseek64(int fd)
            throws Exception {
        QueryResult result = executeSQL("SELECT lo_lseek(" + fd + ", 5, 0);", false);
        String expected = readFile("expected/t4_f_lo_lseek64");
        // verify
        assertEquals(expected, result.getResult());
        return fd;
    }

    /*
     * Test lo_tell64
     */
    public int t4_g_lo_tell64(int fd)
            throws Exception {
        QueryResult result = executeSQL("SELECT lo_tell64(" + fd + ");", false);
        String expected = readFile("expected/t4_d_lo_tell64");
        // verify
        assertEquals(expected, result.getResult());
        return fd;
    }

    /*
     * Test lo_truncate method
     */
    public void t4_h_lo_truncate(int fd, int size)
            throws Exception {
        QueryResult result = executeSQL("select lo_truncate(" + fd + "," + size + ");", false);
        String expected = readFile("expected/t4_h_lo_truncate");
        assertEquals(expected, result.getResult());
    }

    /*
     * Test lo_close
     */
    public int t4_i_lo_close(int fd)
            throws Exception {
        QueryResult result = executeSQL("SELECT lo_close(" + fd + ");");
        String expected = readFile("expected/t4_i_lo_close");
        assertEquals(expected, result.getResult());
        return fd;
    }

    /*
     * Test pg_largeobject_metadata
     */
    public void t4_j_pg_largeobject_metadata(int loid)
            throws Exception {
        executeSQL("set bytea_output = 'escape';");
        QueryResult result = executeSQL("select * from pg_largeobject_metadata where oid = " + loid + ";");
        String expected = readFile("expected/t4_j_pg_largeobject_metadata");
        // verify
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Test pg_largeobject
     */
    public void t4_k_pg_largeobject(int loid)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject where loid = " + loid + ";");
        String expected = readFile("expected/t4_k_pg_largeobject");
        // verify
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Test lo_unlink
     */
    public void t4_l_lo_unlink(int loid)
            throws Exception {
        QueryResult result = executeSQL("select lo_unlink(" + loid + ");");
        String expected = readFile("expected/t4_l_lo_unlink");
        // verify
        assertEquals(expected, result.getResult());
    }

    /*
     * Test pg_largeobject_metadata
     */
    public void t4_m_pg_largeobject_metadata(int loid)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject_metadata where oid = " + loid + ";");
        String expected = readFile("expected/t4_m_pg_largeobject_metadata");
        // verify
        assertEquals(expected, result.getResult());
    }

    /*
     * Test lo_from_bytea
     */
    public int t5_a_lo_from_bytea()
            throws Exception {
        // TODO: probably pick SQL from file
        QueryResult result = executeSQL("SELECT lo_from_bytea(0, '0123456789abcdefghijklmnopqrstuvwxyz'::bytea);");
        // get large object oid
        int loid = Integer.parseInt(getLine(result.getResult(), 1));
        String expected = readFile("expected/t5_a_lo_from_bytea");
        // verify
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
        return loid;
    }

    /*
     * Test lo_from_bytea
     */
    public void t5_d_lo_from_bytea(int loid)
            throws Exception {
        // TODO: probably pick SQL from file
        String exceptionText = "";
        try {
            QueryResult result = executeSQL("SELECT lo_from_bytea(" + loid + ", 'Updated text 123'::bytea);");
        } catch (RuntimeException exception) {
            if(exception.getCause().getClass().getName().compareTo("org.postgresql.util.PSQLException") == 0 &&
                    ((PSQLException)exception.getCause()).getSQLState().compareTo("23505") == 0) {
                exceptionText = ((PSQLException)exception.getCause()).toString();
            }
        }
        String expected = readFile("expected/t5_d_lo_from_bytea");
        // verify
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), exceptionText);
    }

    /*
     * Test lo_put
     */
    public int t5_f_lo_put(int loid)
            throws Exception {
        // TODO: probably pick SQL from file
        QueryResult result = executeSQL("SELECT lo_put(" + loid + ", 4, 'XYZ'::bytea);");
        String expected = readFile("expected/t5_f_lo_put");
        // verify
        assertEquals(expected, result.getResult());
        return loid;
    }

    /*
     * Test pg_largeobject
     */
    public void t5_g_pg_largeobject(int loid)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject where loid = " + loid + ";");
        String expected = readFile("expected/t5_g_pg_largeobject");
        // verify
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Query lo_get
     */
    public static void t5_h_lo_get(int loid)
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
        int loid = t1_a_lo_creat();
        // verify
        t1_b_pg_largeobject_metadata(loid);
        t1_c_pg_largeobject(loid);
        // clean up
        t1_d_lo_unlink(loid);
        // verify
        t1_e_pg_largeobject_metadata(loid);
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
        int loid = t2_a_lo_create();
        // verify
        t2_b_pg_largeobject_metadata(loid);
        t2_c_pg_largeobject(loid);
        // clean up
        t2_d_lo_unlink(loid);
        // verify
        t2_e_pg_largeobject_metadata(loid);
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
        int loid = t3_a_lo_import();
        t3_b_lo_export(loid);
        // verify
        t3_c_pg_largeobject_metadata(loid);
        t3_d_pg_largeobject(loid);
        // clean up
        t3_e_lo_unlink(loid);
        // verify
        t3_f_pg_largeobject_metadata(loid);
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
        int loid = t4_a_lo_import();
        // open lo
        int fd = t4_b_lo_open(loid);
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
        t4_j_pg_largeobject_metadata(loid);
        t4_k_pg_largeobject(loid);
        // clean up
        t4_l_lo_unlink(loid);
        // verify
        t4_m_pg_largeobject_metadata(loid);
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
        int loid = t5_a_lo_from_bytea();
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
        t5_g_pg_largeobject(loid);
        // try lo_get
        t5_h_lo_get(loid);
        // clean up
        lo_unlink(loid);
        // verify
        pg_largeobject_metadata(loid, false);
    }
}
