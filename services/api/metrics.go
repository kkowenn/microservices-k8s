package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/felixge/httpsnoop"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type requestIDKey struct{}

func requestID(ctx context.Context) string { id, _ := ctx.Value(requestIDKey{}).(string); return id }

type telemetry struct {
	registry *prometheus.Registry
	requests *prometheus.CounterVec
	duration *prometheus.HistogramVec
}

func newTelemetry(db *sql.DB) *telemetry {
	t := &telemetry{
		registry: prometheus.NewRegistry(),
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total", Help: "Application HTTP requests by fixed route, method and status.",
		}, []string{"method", "route", "status"}),
		duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name: "http_request_duration_seconds", Help: "Application HTTP request duration in seconds.",
			Buckets: []float64{.01, .025, .05, .1, .25, .3, .5, 1, 2.5, 5, 10},
		}, []string{"method", "route"}),
	}
	t.registry.MustRegister(t.requests, t.duration, collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	if db != nil {
		t.registry.MustRegister(collectors.NewDBStatsCollector(db, "postgres"))
	}
	return t
}

func (t *telemetry) handler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", promhttp.HandlerFor(t.registry, promhttp.HandlerOpts{}))
	return mux
}

func (t *telemetry) instrument(route string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var bytes [16]byte
		if _, err := rand.Read(bytes[:]); err != nil {
			slog.Error("request ID generation failed", "error", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}
		id := hex.EncodeToString(bytes[:])
		w.Header().Set("X-Request-ID", id)
		r = r.WithContext(context.WithValue(r.Context(), requestIDKey{}, id))
		result := httpsnoop.CaptureMetrics(next, w, r)
		method := r.Method
		if method != http.MethodGet && method != http.MethodHead {
			method = "OTHER"
		}
		t.requests.WithLabelValues(method, route, strconv.Itoa(result.Code)).Inc()
		t.duration.WithLabelValues(method, route).Observe(result.Duration.Seconds())
		level := slog.LevelInfo
		if result.Code >= 500 {
			level = slog.LevelError
		}
		slog.Log(r.Context(), level, "request", "request_id", id, "method", method,
			"route", route, "status", result.Code, "duration_ms", float64(result.Duration.Microseconds())/1000)
	})
}
