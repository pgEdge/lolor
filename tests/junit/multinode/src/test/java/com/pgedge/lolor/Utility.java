package com.pgedge.lolor;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.sql.*;
import java.io.*;
import java.util.ArrayList;
import java.util.Properties;

/*
* `Utility` class provides helper methods and common routines
* */

//TODO: remove redundant code / refactor, make similar code as class shared with other classes
public class Utility {
    public static ArrayList<Connection> pgconns = new ArrayList<Connection>();

    private static Properties dbProps;
    private final static String dbPropsFile = "test.properties";

    public static int getSync_delay() {
        return sync_delay;
    }

    //TODO: better alternate for timeout/sleep based mechenism to allow sync up ?
    public static void waitForSync() throws InterruptedException {
        Thread.sleep(sync_delay);
    }
    // sync up delay in miliseconds
    // TODO: put it in properties
    private static int sync_delay = 4000;

    /*
    * Query result
    * It contains executed SQL and results returned
    * */
    public static class QueryResult {
        String sql = "";

        public QueryResult(String sql) {
            this.sql = sql;
        }
        public QueryResult() {}

        ArrayList<String> result = new ArrayList<String>();

        @Override
        public String toString() {
            return sql + "\n" + result.get(0);
        }

        public String getSql() {
            return sql;
        }

        public void setSql(String sql) {
            this.sql = sql;
        }

        public String getResult() {
            if(result.size() < 1) {
                return "";
            }
            return result.get(0);
        }
        public String getResult(int i) {
            return result.get(i);
        }

        public ArrayList<String> getResults() {
            return result;
        }

        public void setResult(String result) {
            if(this.result.size() == 0) {
                this.result.add(result);
            } else {
                this.result.set(0, result);
            }
        }
        public void setResult(String result, int i) {
            if(this.result.size() <= i) {
                this.result.add(result);
            } else {
                this.result.set(i, result);
            }
        }
        public void add(QueryResult queryResult) {
            if(this.sql.isEmpty()) {
                this.sql = queryResult.getSql();
            }
            this.result.add(queryResult.getResult());
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
            if (dbProps.getOrDefault("with_lolor_extension", 1).equals("1")) {
                dbProps.setProperty("options", "options=-c%20search_path=lolor,\"$user\",public,pg_catalog");
            }
            pgconns.add(DriverManager.getConnection(dbProps.getProperty("n1.url") + "?" + dbProps.getProperty("options"),
                                                    dbProps.getProperty("n1.username"),
                                                    dbProps.getProperty("n1.password")));
            pgconns.add(DriverManager.getConnection(dbProps.getProperty("n2.url") + "?" + dbProps.getProperty("options"),
                                                    dbProps.getProperty("n2.username"),
                                                    dbProps.getProperty("n2.password")));
            pgconns.add(DriverManager.getConnection(dbProps.getProperty("n3.url") + "?" + dbProps.getProperty("options"),
                                                    dbProps.getProperty("n3.username"),
                                                    dbProps.getProperty("n3.password")));
            pgconns.forEach(conn-> {
                try {
                    conn.setAutoCommit(false);
                } catch (SQLException e) {
                    throw new RuntimeException(e);
                }
            });
        } catch (SQLException e) {
            throw new RuntimeException(e);
        }
    }

    /*
     * Close the connection
     * */
    public static void disconnectPG()
            throws Exception {
        /*TODO: check if already connection */
        pgconns.forEach(conn -> {
            try {
                conn.close();
            } catch (SQLException e) {
                throw new RuntimeException(e);
            }
        });
    }

    /*
     * Run query and return results
     * Perform commit if asked
     * */
    public static QueryResult executeSQL(Connection conn, String sql, boolean doCommit)
            throws Exception {
        QueryResult result = new QueryResult(sql);
        try {
            StringBuilder sbResult = new StringBuilder();
            PreparedStatement ps = conn.prepareStatement(sql);
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
                conn.commit();
//                executeSQL(conn, "commit;", false);
            }
            result.setResult(sbResult.toString().trim());
            return result;
        } catch (SQLException e) {
            // 02000 = no_data
            if(e.getSQLState().compareTo("02000") == 0) {
                return result;
            } else {
                conn.rollback();
                throw new RuntimeException(e);
            }
        }
    }

    public static QueryResult executeSQL(Connection conn, String sql)
            throws Exception {
        return executeSQL(conn, sql, true);
    }

    public static QueryResult executeSQL(int node, String sql, boolean doCommit)
            throws Exception {
        return executeSQL(pgconns.get(node), sql, doCommit);
    }

    public static QueryResult executeSQL(String sql, boolean doCommit)
            throws Exception {
        return executeSQL(pgconns.get(0), sql, doCommit);
    }

    public static QueryResult executeSQL(int node, String sql)
            throws Exception {
        return executeSQL(pgconns.get(node), sql, true);
    }

    public static QueryResult executeSQL(String sql)
            throws Exception {
        QueryResult queryResult = new QueryResult();
        for(Connection conn : pgconns) {
            queryResult.add(executeSQL(conn, sql, true));
        }
        return queryResult;
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
    public static String lo_creat()
            throws Exception {
        // TODO: probably pick SQL from file
        QueryResult result = executeSQL("select lo_creat(0);", true);
        String loid = getLine(result.getResult(), 1);
        String expected = readFile("expected/lo_creat");
        assertEquals(expected.replace("<xxxx1>", loid), result.getResult());
        return loid;
    }

    /*
     * Execute lo_unlink method
     */
    public static void lo_unlink(String loid)
            throws Exception {
        QueryResult result = executeSQL("select lo_unlink(" + loid + ");", true);
        String expected = readFile("expected/lo_unlink");
        assertEquals(expected, result.getResult());
    }

    /*
     * Query pg_largeobject_metadata table
     */
    public static void pg_largeobject_metadata(String loid, boolean exists)
            throws Exception {
        String expected_file = exists ? "pg_largeobject_metadata_oid_exist" : "pg_largeobject_metadata_oid_not_exist";
        pg_largeobject_metadata(loid, "expected/" + expected_file);
    }

    /*
     * Test pg_largeobject_metadata table
     */
    public static void pg_largeobject_metadata(String loid, String expectedOutFile)
            throws Exception {
        QueryResult useroid_result = executeSQL("SELECT oid FROM pg_roles WHERE rolname = CURRENT_USER;");
        String expected = readFile(expectedOutFile);
        waitForSync();
        QueryResult result = executeSQL("select * from lolor.pg_largeobject_metadata where oid = " + loid + ";");

        for(int i = 0; i < result.getResults().size(); i++) {
            String useroid = getLine(useroid_result.getResult(i), 1);
            assertEquals(expected.replace("<xxxx1>", loid).replace("<xxxx2>", useroid), result.getResult(i));
        }
    }

    /*
     * Test pg_largeobject table
     */
    public static void pg_largeobject(String loid, String expectedOutFile)
            throws Exception {
        String expected = readFile(expectedOutFile);
        waitForSync();
        QueryResult result = executeSQL("select loid, pageno, convert_from(data, 'utf-8') as data from lolor.pg_largeobject where loid = " + loid + ";");

        for(int i = 0; i < result.getResults().size(); i++) {
            assertEquals(expected.replace("<xxxx1>", loid), result.getResult(i));
        }
    }

    /*
     * Query pg_largeobject table
     */
    public static void pg_largeobject(String loid, boolean exists)
            throws Exception {
        String expected_file = exists ? "pg_largeobject_oid_exist" : "pg_largeobject_oid_not_exist";
        pg_largeobject(loid, "expected/" + expected_file);
    }

    /*
     * Query lo_get table
     */
    public static void lo_get(String loid, boolean exists)
            throws Exception {
        QueryResult result = executeSQL("select convert_from(lo_get(" + loid + "), 'utf-8');", true);
        String expected_file = exists ? "lo_get_oid_exist" : "lo_get_oid_not_exist";
        String expected = readFile("expected/" + expected_file);
        assertEquals(expected.replace("<xxxx1>", loid), result.getResult());
    }

    /*
     * Test lo_truncate64 method
     */
    public static void lo_truncate64(String fd, int size)
            throws Exception {
        QueryResult result = executeSQL("select lo_truncate64(" + fd + "," + size + ");", false);
        String expected = readFile("expected/lo_truncate64");
        assertEquals(expected, result.getResult());
    }

    /*
     * Create large Object
     */
    public static String createLargeObject()
            throws Exception {
        String loid = lo_creat();
        // verify
        pg_largeobject_metadata(loid, true);
        return loid;
    }

    /*
     * remove large Object
     */
    public static void deleteLargeObject(String loid)
            throws Exception {
        lo_unlink(loid);
        // verify
        pg_largeobject_metadata(loid, false);
        //TODO: check pg_largeobject as well?
    }

    /*
     * copy file to the database server machine from client
     */
    public static void copyFileToServer(String srcPath, String destPath)
            throws Exception {
        String dataFileText = readFile(srcPath);
        QueryResult result = executeSQL("COPY (SELECT $$" + dataFileText + "$$) TO PROGRAM $$sed 's/\\\\n/\\'$'\\n''/g' > " + destPath + "$$", true);
    }

    /*
     * copy file to the local machine from server
     */
    public static void copyFileToLocal(String srcPath, String destPath)
            throws Exception {
        executeSQL("CREATE TEMP TABLE IF NOT EXISTS copyfile_tmp (data text);", true);
        executeSQL("TRUNCATE copyfile_tmp;", true);
        executeSQL("COPY copyfile_tmp FROM '" + srcPath + "';", true);
        QueryResult result = executeSQL("select string_agg(data, E'\\n') as data from copyfile_tmp;", true);
        StringBuilder sb = new StringBuilder(result.getResult());
        sb.delete(0, sb.indexOf("\n") + 1);
        writeFile(destPath, sb.toString());
    }
}
