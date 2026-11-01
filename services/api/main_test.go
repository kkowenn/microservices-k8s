package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// A driver exercises database/sql cancellation and row scanning without a live DB.
type testDriver struct{}
type testConn struct{ mode string }
type testRows struct{ sent bool }

func init()                                              { sql.Register("review-test", testDriver{}) }
func (testDriver) Open(mode string) (driver.Conn, error) { return &testConn{mode}, nil }
func (*testConn) Prepare(string) (driver.Stmt, error)    { return nil, errors.New("unused") }
func (*testConn) Close() error                           { return nil }
func (*testConn) Begin() (driver.Tx, error)              { return nil, errors.New("unused") }
func (c *testConn) Ping(ctx context.Context) error {
	if c.mode == "offline" {
		return errors.New("database offline")
	}
	if c.mode == "blocked" {
		<-ctx.Done()
		return ctx.Err()
	}
	return nil
}
func (c *testConn) QueryContext(ctx context.Context, _ string, _ []driver.NamedValue) (driver.Rows, error) {
	if c.mode == "blocked" {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	if c.mode == "offline" {
		return nil, errors.New("database offline")
	}
	return &testRows{}, nil
}
func (*testRows) Columns() []string { return []string{"id", "name"} }
func (*testRows) Close() error      { return nil }
func (r *testRows) Next(values []driver.Value) error {
	if r.sent {
		return io.EOF
	}
	r.sent = true
	values[0], values[1] = int64(1), "<img src=x onerror=alert(1)>"
	return nil
}

func testApp(t *testing.T, mode string) application {
	t.Helper()
	db, err := sql.Open("review-test", mode)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return application{db: db}
}

func TestHealthDuringDatabaseOutage(t *testing.T) {
	app := testApp(t, "offline")
	for path, want := range map[string]int{"/livez": 200, "/readyz": 503, "/health": 503} {
		rr := httptest.NewRecorder()
		app.routes().ServeHTTP(rr, httptest.NewRequest("GET", path, nil))
		if rr.Code != want {
			t.Fatalf("%s: got %d, want %d", path, rr.Code, want)
		}
	}
}

func TestReadinessTimesOut(t *testing.T) {
	app := testApp(t, "blocked")
	rr := httptest.NewRecorder()
	start := time.Now()
	app.routes().ServeHTTP(rr, httptest.NewRequest("GET", "/readyz", nil))
	if rr.Code != 503 || time.Since(start) > healthTimeout+time.Second {
		t.Fatalf("readiness did not return promptly: status %d", rr.Code)
	}
}

func TestItemsDeadlineAndRequestCancellation(t *testing.T) {
	for _, canceled := range []bool{false, true} {
		app := testApp(t, "blocked")
		ctx, cancel := context.WithCancel(context.Background())
		if canceled {
			cancel()
		}
		rr := httptest.NewRecorder()
		start := time.Now()
		app.routes().ServeHTTP(rr, httptest.NewRequest("GET", "/api/items", nil).WithContext(ctx))
		cancel()
		limit := queryTimeout + time.Second
		if canceled {
			limit = time.Second
		}
		if rr.Code != 503 || time.Since(start) > limit {
			t.Fatalf("query failed cancellation/deadline check: %d", rr.Code)
		}
		if !strings.HasPrefix(rr.Header().Get("Content-Type"), "application/json") {
			t.Fatal("error must be JSON")
		}
	}
}

func TestItemsAndMethods(t *testing.T) {
	app := testApp(t, "healthy")
	rr := httptest.NewRecorder()
	app.routes().ServeHTTP(rr, httptest.NewRequest("GET", "/api/items", nil))
	var items []Item
	if err := json.Unmarshal(rr.Body.Bytes(), &items); err != nil {
		t.Fatal(err)
	}
	if rr.Code != 200 || len(items) != 1 || items[0].ID != 1 || items[0].Name != "<img src=x onerror=alert(1)>" {
		t.Fatalf("unexpected response: %s", rr.Body.String())
	}
	rr = httptest.NewRecorder()
	app.routes().ServeHTTP(rr, httptest.NewRequest("POST", "/api/items", nil))
	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST status: %d", rr.Code)
	}
}

func TestDatabaseDSNRequiresCredentialsAndEscapesValues(t *testing.T) {
	for _, name := range []string{"DATABASE_USER", "DATABASE_PASSWORD", "DATABASE_NAME"} {
		t.Setenv(name, "")
	}
	if _, err := databaseDSN(); err == nil {
		t.Fatal("missing credentials accepted")
	}
	t.Setenv("DATABASE_USER", "reader")
	t.Setenv("DATABASE_PASSWORD", "space ' @:/?& password")
	t.Setenv("DATABASE_NAME", "demodb")
	t.Setenv("DATABASE_SSLMODE", "verify-full")
	dsn, err := databaseDSN()
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	password, _ := u.User.Password()
	if password != "space ' @:/?& password" || u.Query().Get("connect_timeout") != "5" || u.Query().Get("sslmode") != "verify-full" {
		t.Fatal("DSN escaping or timeouts incorrect")
	}
}
