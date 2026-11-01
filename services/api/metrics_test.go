package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMetricsAndLogsUseFixedLabelsAndSeparateListener(t *testing.T) {
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	app := testApp(t, "healthy")
	db := app.db.(*sql.DB)
	db.SetMaxOpenConns(10)
	app.telemetry = newTelemetry(db)
	routes := app.routes()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/api/items?private=do-not-log", nil)
	req.Header.Set("Authorization", "do-not-log")
	routes.ServeHTTP(rr, req)
	if rr.Code != 200 || len(rr.Header().Get("X-Request-ID")) != 32 {
		t.Fatalf("response: %d %v", rr.Code, rr.Header())
	}
	var entry map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(logs.Bytes()), &entry); err != nil {
		t.Fatal(err)
	}
	if entry["request_id"] != rr.Header().Get("X-Request-ID") || entry["route"] != "/api/items" || entry["status"] != float64(200) {
		t.Fatalf("log: %v", entry)
	}
	if strings.Contains(logs.String(), "do-not-log") {
		t.Fatal("sensitive input logged")
	}
	// Health and scraping must not contribute to application golden signals.
	for _, path := range []string{"/livez", "/readyz", "/health", "/metrics", "/unknown/123"} {
		routes.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", path, nil))
	}
	metrics := httptest.NewRecorder()
	app.telemetry.handler().ServeHTTP(metrics, httptest.NewRequest("GET", "/metrics", nil))
	body := metrics.Body.String()
	for _, want := range []string{
		`http_requests_total{method="GET",route="/api/items",status="200"} 1`,
		`http_request_duration_seconds_count{method="GET",route="/api/items"} 1`,
		`go_sql_max_open_connections{db_name="postgres"} 10`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("missing metric %s", want)
		}
	}
	if strings.Contains(body, "private") || strings.Contains(body, `route="/livez"`) {
		t.Fatal("unbounded labels or probes included")
	}
	rr = httptest.NewRecorder()
	routes.ServeHTTP(rr, httptest.NewRequest("GET", "/metrics", nil))
	if rr.Code != http.StatusNotFound {
		t.Fatal("metrics exposed on public application listener")
	}
	rr = httptest.NewRecorder()
	app.telemetry.handler().ServeHTTP(rr, httptest.NewRequest("GET", "/api/items", nil))
	if rr.Code != http.StatusNotFound {
		t.Fatal("application exposed on metrics listener")
	}
	// A second instance must be independent, not collide with global collectors.
	second := newTelemetry(db)
	families, err := second.registry.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, family := range families {
		if family.GetName() == "http_requests_total" {
			t.Fatal("registry leaked requests across instances")
		}
	}
}

func TestDatabaseFailureMetricsAndStructuredErrorLog(t *testing.T) {
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	app := testApp(t, "offline")
	app.telemetry = newTelemetry(app.db.(*sql.DB))
	rr := httptest.NewRecorder()
	app.routes().ServeHTTP(rr, httptest.NewRequest("GET", "/api/items", nil))
	if rr.Code != 503 {
		t.Fatalf("status: %d", rr.Code)
	}
	for _, line := range bytes.Split(bytes.TrimSpace(logs.Bytes()), []byte("\n")) {
		var entry map[string]any
		if err := json.Unmarshal(line, &entry); err != nil {
			t.Fatal(err)
		}
		if entry["level"] != "ERROR" || entry["request_id"] != rr.Header().Get("X-Request-ID") {
			t.Fatalf("log: %v", entry)
		}
	}
	metrics := httptest.NewRecorder()
	app.telemetry.handler().ServeHTTP(metrics, httptest.NewRequest("GET", "/metrics", nil))
	if !strings.Contains(metrics.Body.String(), `http_requests_total{method="GET",route="/api/items",status="503"} 1`) {
		t.Fatal("failed request not counted")
	}
}
