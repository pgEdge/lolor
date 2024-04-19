package lolor_tests

import (
	"context"
	"fmt"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"
)

var conn *pgx.Conn

// test input data
var data1 string = "0123456789abcdefghijklmnopqrstuvwxyz"

/*
 * Connect with PG
 */
func connectPG() {
	var err error
	ctx := context.Background()
	// urlExample := "postgres://username:password@localhost:5432/database_name"
	conn, err = pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Unable to connect to database: %v\n", err)
		os.Exit(1)
	}
}

/*
 * Execute the query on the database server
 */
func executeSQL(query string) {
	ctx := context.Background()
	rows, err := conn.Query(ctx, query)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Unable to execute query: %v\n", err)
		os.Exit(1)
	}
	rows.Close()
}

/*
 * Initialize database
 */
func initDB() {
	createExt := "CREATE EXTENSION IF NOT EXISTS lolor;"
	executeSQL(createExt)
}

/*
 * Create large object and return the id
 */
func createlo(data string, t *testing.T) uint32 {
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatalf("%v", err)
	}

	lo := tx.LargeObjects()
	id, err := lo.Create(ctx, 0)
	if err != nil {
		t.Fatalf("%v", err)
	}

	obj, err := lo.Open(ctx, id, pgx.LargeObjectModeWrite)
	if err != nil {
		t.Fatalf("%v", err)
	}

	n, err := obj.Write([]byte(data))
	_ = n
	if err != nil {
		t.Fatalf("%v", err)
	}

	err = obj.Close()
	if err != nil {
		t.Fatalf("%v", err)
	}

	// Commit the transaction
	err = tx.Commit(ctx)
	if err != nil {
		t.Fatalf("%v", err)
	}

	return id
}

/*
 * Read the large object and return the data
 */
func readlo(loid uint32, size int, t *testing.T) string {
	var n int
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatalf("%v", err)
	}

	lo := tx.LargeObjects()

	obj, err := lo.Open(ctx, loid, pgx.LargeObjectModeRead)
	if err != nil {
		t.Fatalf("%v", err)
	}

	data := make([]byte, size)
	n, err = obj.Read(data)
	_ = n
	if err != nil {
		t.Fatalf("%v", err)
	}

	err = obj.Close()
	if err != nil {
		t.Fatalf("%v", err)
	}

	// Commit the transaction
	err = tx.Commit(ctx)
	if err != nil {
		t.Fatalf("%v", err)
	}

	return string(data)
}

/*
 * Drop the large object
 */
func droplo(loid uint32, t *testing.T) {
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatalf("%v", err)
	}

	lo := tx.LargeObjects()

	err = lo.Unlink(ctx, loid)
	if err != nil {
		t.Fatalf("%v", err)
	}

	// Commit the transaction
	err = tx.Commit(ctx)
	if err != nil {
		t.Fatalf("%v", err)
	}
}

/*
 * Perform seek operation on large object and return the new cursor position
 */
func seeklo(loid uint32, data string, t *testing.T) int64 {
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatalf("%v", err)
	}

	lo := tx.LargeObjects()

	obj, err := lo.Open(ctx, loid, pgx.LargeObjectModeRead|pgx.LargeObjectModeWrite)
	if err != nil {
		t.Fatalf("%v", err)
	}

	pos, err := obj.Seek(15, 0)
	if err != nil {
		t.Fatalf("%v", err)
	}

	n, err := obj.Write([]byte(data))
	_ = n
	if err != nil {
		t.Fatalf("%v", err)
	}

	err = obj.Close()
	if err != nil {
		t.Fatalf("%v", err)
	}

	// Commit the transaction
	err = tx.Commit(ctx)
	if err != nil {
		t.Fatalf("%v", err)
	}

	return pos
}

/*
 * Perform the tell operatoin on large object and return the current positions
 */
func telllo(loid uint32, data string, t *testing.T) (int64, int64) {
	var pos1, pos2 int64
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatalf("%v", err)
	}

	lo := tx.LargeObjects()

	obj, err := lo.Open(ctx, loid, pgx.LargeObjectModeRead|pgx.LargeObjectModeWrite)
	if err != nil {
		t.Fatalf("%v", err)
	}

	pos1, err = obj.Tell()
	if err != nil {
		t.Fatalf("%v", err)
	}

	n, err := obj.Write([]byte(data))
	_ = n
	if err != nil {
		t.Fatalf("%v", err)
	}

	pos2, err = obj.Tell()
	if err != nil {
		t.Fatalf("%v", err)
	}

	err = obj.Close()
	if err != nil {
		t.Fatalf("%v", err)
	}

	// Commit the transaction
	err = tx.Commit(ctx)
	if err != nil {
		t.Fatalf("%v", err)
	}

	return pos1, pos2
}

/*
 * Perform truncate operation on large object
 */
func truncatelo(loid uint32, size int, t *testing.T) {
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatalf("%v", err)
	}

	lo := tx.LargeObjects()

	obj, err := lo.Open(ctx, loid, pgx.LargeObjectModeRead|pgx.LargeObjectModeWrite)
	if err != nil {
		t.Fatalf("%v", err)
	}

	err = obj.Truncate(int64(size))
	if err != nil {
		t.Fatalf("%v", err)
	}

	err = obj.Close()
	if err != nil {
		t.Fatalf("%v", err)
	}

	// Commit the transaction
	err = tx.Commit(ctx)
	if err != nil {
		t.Fatalf("%v", err)
	}
}

/*
 * Basic data lo write and read test
 */
func TestLOReadWrite(t *testing.T) {
	var loid uint32 = createlo(data1, t)
	var lo_data string = readlo(loid, len(data1), t)
	droplo(loid, t)
	if data1 != lo_data {
		t.Errorf("lo_data = %s; want %s", lo_data, data1)
	}
}

/*
 * Basic data lo seek test
 */
func TestLOSeek(t *testing.T) {
	var expectedData string = "0123456789abcde<ADDEDDATA>qrstuvwxyz"
	var loid uint32 = createlo(data1, t)
	var pos int64 = seeklo(loid, "<ADDEDDATA>", t)
	var lo_data string = readlo(loid, len(data1), t)
	droplo(loid, t)
	if expectedData != lo_data {
		t.Errorf("lo_data = %s; want %s", lo_data, expectedData)
	}
	if pos != 15 {
		t.Errorf("seek position = %d; want %d", pos, 15)
	}
}

/*
 * Basic data lo tell test
 */
func TestLOTell(t *testing.T) {
	var expectedData string = "<ADDEDDATA>bcdefghijklmnopqrstuvwxyz"
	var loid uint32 = createlo(data1, t)
	pos1, pos2 := telllo(loid, "<ADDEDDATA>", t)
	var lo_data string = readlo(loid, len(data1), t)
	droplo(loid, t)
	if expectedData != lo_data {
		t.Errorf("lo_data = %s; want %s", lo_data, expectedData)
	}
	if pos1 != 0 {
		t.Errorf("seek position 1 = %d; want %d", pos1, 0)
	}
	if pos2 != 11 {
		t.Errorf("seek position 2 = %d; want %d", pos2, 11)
	}
}

/*
 * Basic data lo truncate test
 */
func TestLOTruncate(t *testing.T) {
	var expectedData string = "0123456789"
	var size int = 10
	var loid uint32 = createlo(data1, t)
	truncatelo(loid, size, t)
	var lo_data string = readlo(loid, size, t)
	droplo(loid, t)
	if expectedData != lo_data {
		t.Errorf("lo_data = %s; want %s", lo_data, expectedData)
	}
}

func TestMain(m *testing.M) {
	connectPG()
	initDB()
	code := m.Run()
	defer conn.Close(context.Background())
	os.Exit(code)
}
