package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	_ "github.com/lib/pq"
)

var db *sql.DB

type Item struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

type HealthResponse struct {
	Status   string `json:"status"`
	Database string `json:"database,omitempty"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8000"
	}

	var err error
	db, err = connectWithRetry(10, 2*time.Second)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer db.Close()

	log.Println("Connected to database")

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/api/items", itemsHandler)

	log.Printf("API service running on port %s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func connectWithRetry(maxRetries int, baseDelay time.Duration) (*sql.DB, error) {
	dsn := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		getEnv("DATABASE_HOST", "localhost"),
		getEnv("DATABASE_PORT", "5432"),
		getEnv("DATABASE_USER", "demouser"),
		getEnv("DATABASE_PASSWORD", "demopass"),
		getEnv("DATABASE_NAME", "demodb"),
	)

	var lastErr error
	for i := 0; i < maxRetries; i++ {
		conn, err := sql.Open("postgres", dsn)
		if err != nil {
			lastErr = err
			log.Printf("Attempt %d/%d: failed to open DB: %v", i+1, maxRetries, err)
		} else if err = conn.Ping(); err != nil {
			lastErr = err
			conn.Close()
			log.Printf("Attempt %d/%d: failed to ping DB: %v", i+1, maxRetries, err)
		} else {
			conn.SetMaxOpenConns(10)
			conn.SetMaxIdleConns(5)
			conn.SetConnMaxLifetime(5 * time.Minute)
			return conn, nil
		}

		delay := baseDelay * time.Duration(1<<uint(i))
		if delay > 30*time.Second {
			delay = 30 * time.Second
		}
		log.Printf("Retrying in %v...", delay)
		time.Sleep(delay)
	}
	return nil, fmt.Errorf("gave up after %d attempts: %w", maxRetries, lastErr)
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	resp := HealthResponse{Status: "ok"}
	if err := db.Ping(); err != nil {
		resp.Status = "degraded"
		resp.Database = "unreachable"
		w.WriteHeader(http.StatusServiceUnavailable)
	} else {
		resp.Database = "connected"
	}

	json.NewEncoder(w).Encode(resp)
}

func itemsHandler(w http.ResponseWriter, r *http.Request) {
	rows, err := db.Query("SELECT id, name FROM items ORDER BY id")
	if err != nil {
		http.Error(w, `{"error":"database query failed"}`, http.StatusInternalServerError)
		log.Printf("Error querying items: %v", err)
		return
	}
	defer rows.Close()

	items := []Item{}
	for rows.Next() {
		var item Item
		if err := rows.Scan(&item.ID, &item.Name); err != nil {
			http.Error(w, `{"error":"failed to scan row"}`, http.StatusInternalServerError)
			log.Printf("Error scanning row: %v", err)
			return
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		http.Error(w, `{"error":"row iteration error"}`, http.StatusInternalServerError)
		log.Printf("Row iteration error: %v", err)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(items)
}
