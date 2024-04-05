package com.pgedge.lolor;

import static com.pgedge.lolor.Utility.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.AfterAll;

import static org.junit.jupiter.api.Assertions.assertEquals;

/*
* `TestLOSql` class tries to SQL command related to Large Objects e.g.
*    ALTER LARGE OBJECT ...
*    GRANT ... ON LARGE OBJECT
*    COMMENT ON LARGE OBJECT ...
* */

//TODO: remove redundant code / refactor, make similar code as class shared with other classes
public class TestLOSql {
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
     * Test ALTER LARGE OBJECT
     */
    public void t1_alter_large_object(int loid)
            throws Exception {
        QueryResult result = executeSQL("ALTER LARGE OBJECT " + loid + " OWNER TO CURRENT_USER;", true);
        String expected = readFile("expected/t1_alter_large_object");
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Test GRANT ... ON LARGE OBJECT
     */
    public void t2_grant_on_large_object(int loid)
            throws Exception {
        QueryResult result = executeSQL("GRANT UPDATE ON LARGE OBJECT " + loid + " TO CURRENT_USER;", true);
        String expected = readFile("expected/t2_grant_on_large_object");
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Test COMMENT ON LARGE OBJECT
     */
    public void t3_comment_on_large_object(int loid)
            throws Exception {
        QueryResult result = executeSQL("COMMENT ON LARGE OBJECT " + loid + " IS 'Testing Comment on large object';", true);
        String expected = readFile("expected/t3_comment_on_large_object");
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Test REVOKE ... ON LARGE OBJECT
     */
    public void t4_revoke_on_large_object(int loid)
            throws Exception {
        QueryResult result = executeSQL("REVOKE UPDATE ON LARGE OBJECT " + loid + " FROM CURRENT_USER;", true);
        String expected = readFile("expected/t4_revoke_on_large_object");
        assertEquals(expected, result.getResult());
    }

    /*
     * Test SECURITY LABEL ON LARGE OBJECT ...
     */
    public void t5_security_label_on_large_object(int loid)
            throws Exception {
        QueryResult result = executeSQL("SECURITY LABEL ON LARGE OBJECT " + loid + " IS 'system_u:object_r:sepgsql_table_t:s0';", true);
        String expected = readFile("expected/t5_security_label_on_large_object");
        assertEquals(expected, result.getResult());
    }

    /*
     * Basic test that covers i.e.
     *  lo_creat
     *  lo_unlink
     *  pg_largeobject_metadata catalog table
     *  ALTER LARGE OBJECT
     */
    @Test
    public void t1()
            throws Exception {
        int loid = createLargeObject();
        // run test
        t1_alter_large_object(loid);
        // clean up
        deleteLargeObject(loid);
    }

    /*
     * Basic test that covers i.e.
     *  lo_creat
     *  lo_unlink
     *  pg_largeobject_metadata catalog table
     *  GRANT ... ON LARGE OBJECT
     */
    @Test
    public void t2()
            throws Exception {
        int loid = createLargeObject();
        // run test
        t2_grant_on_large_object(loid);
        // clean up
        deleteLargeObject(loid);
    }

    /*
     * Basic test that covers i.e.
     *  lo_creat
     *  lo_unlink
     *  pg_largeobject_metadata catalog table
     *  COMMENT ON LARGE OBJECT
     */
    @Test
    public void t3()
            throws Exception {
        int loid = createLargeObject();
        // run test
        t3_comment_on_large_object(loid);
        // clean up
        deleteLargeObject(loid);
    }

    /*
     * Basic test that covers i.e.
     *  lo_creat
     *  lo_unlink
     *  pg_largeobject_metadata catalog table
     *  REVOKE ... ON LARGE OBJECT
     */
    @Test
    public void t4()
            throws Exception {
        int loid = createLargeObject();
        // run test
        t4_revoke_on_large_object(loid);
        // clean up
        deleteLargeObject(loid);
    }

    /*
     * Basic test that covers i.e.
     *  lo_creat
     *  lo_unlink
     *  pg_largeobject_metadata catalog table
     *  SECURITY LABEL ON LARGE OBJECT
     */
    @Test
    public void t5()
            throws Exception {
        int loid = createLargeObject();
        // run test
        t5_security_label_on_large_object(loid);
        // clean up
        deleteLargeObject(loid);
    }
}
