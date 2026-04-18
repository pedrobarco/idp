package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	message := os.Getenv("HELLO_MESSAGE")
	if message == "" {
		message = "Hello, World!"
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"message": message,
		})
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})

	addr := ":8080"
	log.Printf("Starting server on %s (message=%q)", addr, message)
	log.Fatal(http.ListenAndServe(addr, nil))
}
