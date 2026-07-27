package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

type Item struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

type HealthResponse struct {
	Status string `json:"status"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "3000"
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(HealthResponse{Status: "ok"})
	})

	mux.HandleFunc("/api/items", func(w http.ResponseWriter, r *http.Request) {
		items := []Item{
			{ID: 1, Name: "Item A"},
			{ID: 2, Name: "Item B"},
			{ID: 3, Name: "Item C"},
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(items)
	})

	log.Printf("API service running on port %s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
