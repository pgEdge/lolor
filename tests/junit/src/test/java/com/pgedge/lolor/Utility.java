package com.pgedge.lolor;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.sql.*;
import java.io.*;
import java.util.Properties;

/*
* `TestLOSql` class tries to SQL command related to Large Objects e.g.
*    ALTER LARGE OBJECT ...
*    GRANT ... ON LARGE OBJECT
*    COMMENT ON LARGE OBJECT ...
* */

//TODO: remove redundant code / refactor, make similar code as class shared with other classes
public class Utility {
    public static Connection getPgconn() {
        return pgconn;
    }

    private static Connection pgconn = null;
    private static Properties dbProps;
    private final static String dbPropsFile = "test.properties";

    /*
    * Query result
    * It contains executed SQL and results returned
    * */
    public static class QueryResult {
        String sql;

        public QueryResult(String sql) {
            this.sql = sql;
            this.result = "";
        }

        String result;

        @Override
        public String toString() {
            return sql + "\n" + result;
        }

        public String getSql() {
            return sql;
        }

        public void setSql(String sql) {
            this.sql = sql;
        }

        public String getResult() {
            return result;
        }

        public void setResult(String result) {
            this.result = result;
        }
    }

    /*
     * load property file
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
            if (dbProps.getOrDefault("with_lolor_extension", 1).equals("1")) {
                dbProps.setProperty("options", "-c search_path=lolor,\"$user\",public,pg_catalog");
            }

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
     * Run query and return results
     * Perform commit if asked
     * */
    public static QueryResult executeSQL(String sql, boolean doCommit)
            throws Exception {
        QueryResult result = new QueryResult(sql);
        try {
            StringBuilder sbResult = new StringBuilder();
            PreparedStatement ps = pgconn.prepareStatement(sql);
            ResultSet rs = ps.executeQuery();
            ResultSetMetaData rsmd = rs.getMetaData();
            int columnsNumber = rsmd.getColumnCount();
            for (int i = 1; i <= columnsNumber; i++) {
                if (i > 1) sbResult.append(",");
                sbResult.append(rsmd.getColumnName(i));
            }
            sbResult.append("\n");
            if (true) {
                while (rs.next()) {
                    for (int i = 1; i <= columnsNumber; i++) {
                        if (i > 1) sbResult.append(",");
                        String columnValue = rs.getString(i);
                        sbResult.append(columnValue);
                    }
                    sbResult.append("\n");
                }
            }
            if(doCommit) {
                pgconn.commit();
            }
            result.setResult(sbResult.toString().trim());
            return result;
        } catch (SQLException e) {
            // 02000 = no_data
            if(e.getSQLState().compareTo("02000") == 0) {
                return result;
            } else {
                pgconn.rollback();
                throw new RuntimeException(e);
            }
        }
    }

    public static QueryResult executeSQL(String sql)
            throws Exception {
        return executeSQL(sql, false);
    }

    /*
     * Initialize database
     * */
    public static void initDB()
            throws Exception {
        String createExt = "CREATE EXTENSION IF NOT EXISTS lolor;";
        String dropExt = "DROP EXTENSION IF EXISTS lolor;";
        if (dbProps.getOrDefault("with_lolor_extension", 1).equals("1")) {
            executeSQL(createExt);
        } else {
            executeSQL(dropExt);
        }
    }

    /*
     * Read disk file and return all the contents as String
     */
    public static String readFile(String fname)
            throws Exception {
        FileInputStream fis = new FileInputStream(fname);
        byte[] buffer = new byte[10];
        StringBuilder sb = new StringBuilder();
        while (fis.read(buffer) != -1) {
            sb.append(new String(buffer));
            buffer = new byte[10];
        }
        fis.close();
        return sb.toString().trim();
    }

    /*
    * Write String contents as disk file
    * */
    public static void writeFile(String fname, String content)
            throws Exception {
        Files.write(Paths.get(fname), content.getBytes());
    }

    /*
    * Count the number of lines in the String
    * */
    public static int numberOfLines(String str){
        return str.split("\r\n|\r|\n").length;
    }

    /*
    * Compare two Strings
    * Pass line numbers as argument to be compared
    * */
    public static boolean compareLines(String str1, String str2, int... args){
        String[] strArr1 = str1.split("\r\n|\r|\n");
        String[] strArr2 = str2.split("\r\n|\r|\n");
        if(args != null && args.length != 0) {
            for (int n : args) {
                if (strArr1.length <= n || strArr2.length <= n ||
                        strArr1[n].compareTo(strArr2[n]) != 0) {
                    return false;
                }
            }
        } else {
            return str1.compareTo(str2) == 0;
        }
        return true;
    }

    /*
    * Get particular line from multi line String
    * */
    public static String getLine(String str, int line){
        String[] strArr = str.split("\r\n|\r|\n");
        if(strArr.length <= line) {
            return "";
        }
        return strArr[line];
    }

    /*
     * Execute lo_creat method
     */
    public static int lo_creat()
            throws Exception {
        // TODO: probably pick SQL from file
        QueryResult result = executeSQL("select lo_creat(0);", true);
        int loid = Integer.parseInt(getLine(result.getResult(), 1));
        String expected = readFile("expected/lo_creat");
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
        return loid;
    }

    /*
     * Execute lo_unlink method
     */
    public static void lo_unlink(int loid)
            throws Exception {
        QueryResult result = executeSQL("select lo_unlink(" + loid + ");", true);
        String expected = readFile("expected/lo_unlink");
        assertEquals(expected, result.getResult());
    }

    /*
     * Query pg_largeobject_metadata table
     */
    public static void pg_largeobject_metadata(int loid, boolean exists)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject_metadata where oid = " + loid + ";", true);
        String expected_file = exists ? "pg_largeobject_metadata_oid_exist" : "pg_largeobject_metadata_oid_not_exist";
        String expected = readFile("expected/" + expected_file);
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Query pg_largeobject table
     */
    public static void pg_largeobject(int loid, boolean exists)
            throws Exception {
        QueryResult result = executeSQL("select * from pg_largeobject where loid = " + loid + ";");
        String expected_file = exists ? "pg_largeobject_oid_exist" : "pg_largeobject_oid_not_exist";
        String expected = readFile("expected/" + expected_file);
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Query lo_get table
     */
    public static void lo_get(int loid, boolean exists)
            throws Exception {
        QueryResult result = executeSQL("select convert_from(lo_get(" + loid + "), 'utf-8');", true);
        String expected_file = exists ? "lo_get_oid_exist" : "lo_get_oid_not_exist";
        String expected = readFile("expected/" + expected_file);
        assertEquals(expected.replace("<xxxx1>", String.valueOf(loid)), result.getResult());
    }

    /*
     * Test lo_truncate64 method
     */
    public static void lo_truncate64(int fd, int size)
            throws Exception {
        QueryResult result = executeSQL("select lo_truncate64(" + fd + "," + size + ");", false);
        String expected = readFile("expected/lo_truncate64");
        assertEquals(expected, result.getResult());
    }

    /*
     * Create large Object
     */
    public static int createLargeObject()
            throws Exception {
        int loid = lo_creat();
        // verify
        pg_largeobject_metadata(loid, true);
        return loid;
    }

    /*
     * remove large Object
     */
    public static void deleteLargeObject(int loid)
            throws Exception {
        lo_unlink(loid);
        // verify
        pg_largeobject_metadata(loid, false);
        //TODO: check pg_largeobject as well?
    }
}
