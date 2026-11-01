package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/lib/pq"
)

const (
	healthTimeout = 2 * time.Second
	queryTimeout  = 5 * time.Second
)

type database interface {
	PingContext(context.Context) error
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}

type application struct {
	db        database
	telemetry *telemetry
}

type Item struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

type HealthResponse struct {
	Status   string `json:"status"`
	Database string `json:"database,omitempty"`
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if err := run(); err != nil {
		slog.Error("API stopped", "error", err)
		os.Exit(1)
	}
}

func run() error {
	dsn, err := databaseDSN()
	if err != nil {
		return err
	}
	// Open a lazy pool so HTTP liveness stays available while PostgreSQL starts
	// or recovers. Readiness checks the connection on each request.
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return errors.New("invalid database configuration")
	}
	defer db.Close()
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	metrics := newTelemetry(db)
	app := application{db: db, telemetry: metrics}
	server := &http.Server{
		Addr:              ":" + getEnv("PORT", "8000"),
		Handler:           app.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	metricsServer := &http.Server{
		Addr: ":" + getEnv("METRICS_PORT", "9090"), Handler: metrics.handler(),
		ReadHeaderTimeout: 5 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		for _, srv := range []*http.Server{server, metricsServer} {
			if err := srv.Shutdown(shutdownCtx); err != nil {
				slog.Error("HTTP shutdown", "error", err)
				srv.Close()
			}
		}
	}()
	slog.Info("API started", "address", server.Addr, "metrics_address", metricsServer.Addr)
	serverErrors := make(chan error, 2)
	go func() { serverErrors <- metricsServer.ListenAndServe() }()
	go func() { serverErrors <- server.ListenAndServe() }()
	err = <-serverErrors
	stop()
	<-shutdownDone
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func databaseDSN() (string, error) {
	for _, name := range []string{"DATABASE_USER", "DATABASE_PASSWORD", "DATABASE_NAME"} {
		if os.Getenv(name) == "" {
			return "", fmt.Errorf("%s is required", name)
		}
	}
	u := url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(os.Getenv("DATABASE_USER"), os.Getenv("DATABASE_PASSWORD")),
		Host:   net.JoinHostPort(getEnv("DATABASE_HOST", "localhost"), getEnv("DATABASE_PORT", "5432")),
		Path:   "/" + os.Getenv("DATABASE_NAME"),
	}
	q := u.Query()
	q.Set("connect_timeout", "5")
	q.Set("sslmode", getEnv("DATABASE_SSLMODE", "disable"))
	u.RawQuery = q.Encode()
	return u.String(), nil
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func (app application) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /livez", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, HealthResponse{Status: "ok"})
	})
	mux.HandleFunc("GET /readyz", app.healthHandler)
	mux.HandleFunc("GET /health", app.healthHandler) // Backwards-compatible readiness alias.
	items := http.Handler(http.HandlerFunc(app.itemsHandler))
	if app.telemetry != nil {
		items = app.telemetry.instrument("/api/items", items)
	}
	mux.Handle("GET /api/items", items)
	return mux
}

func (app application) healthHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), healthTimeout)
	defer cancel()
	if err := app.db.PingContext(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, HealthResponse{Status: "degraded", Database: "unreachable"})
		return
	}
	writeJSON(w, http.StatusOK, HealthResponse{Status: "ok", Database: "connected"})
}

func (app application) itemsHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), queryTimeout)
	defer cancel()
	rows, err := app.db.QueryContext(ctx, "SELECT id, name FROM items ORDER BY id")
	if err != nil {
		slog.ErrorContext(r.Context(), "database query failed", "request_id", requestID(r.Context()), "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "database query failed"})
		return
	}
	defer rows.Close()

	items := []Item{}
	for rows.Next() {
		var item Item
		if err := rows.Scan(&item.ID, &item.Name); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to scan row"})
			return
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "row iteration error"})
		return
	}
	writeJSON(w, http.StatusOK, items)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Error("response encoding failed", "error", err)
	}
}
