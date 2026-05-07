// payments-service: simulates a payment gateway.
// Intentionally injects latency and failures so we have something interesting to observe.
package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"time"
)

type ChargeRequest struct {
	AmountCents   int    `json:"amount_cents"`
	CustomerEmail string `json:"customer_email"`
}

type ChargeResponse struct {
	PaymentID   string `json:"payment_id"`
	AmountCents int    `json:"amount_cents"`
	Status      string `json:"status"`
}

var (
	logger      *slog.Logger
	failureRate float64 // 0.0 to 1.0 — chance any single charge will fail
	maxLatency  int     // max simulated processing latency in ms
)

func main() {
	// JSON structured logger (Go 1.21+ has slog built in).
	logger = slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))

	failureRate = parseFloatEnv("FAILURE_RATE", 0.10) // default 10% failure
	maxLatency = parseIntEnv("MAX_LATENCY_MS", 800)

	logger.Info("payments_service_starting", "failure_rate", failureRate, "max_latency_ms", maxLatency)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/charge", chargeHandler)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	logger.Info("payments_service_listening", "port", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		logger.Error("server_failed", "err", err)
		os.Exit(1)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"ok","service":"payments"}`))
}

func chargeHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req ChargeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		logger.Warn("invalid_charge_request", "err", err)
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	// Simulate processing time (uniform 50ms..maxLatency ms).
	// Occasionally inject a much longer "slow" call (5% of the time)
	// to create p99 spikes — great for demoing latency anomaly detection.
	latency := 50 + rand.Intn(maxLatency)
	if rand.Float64() < 0.05 {
		latency += 1500 + rand.Intn(2000) // slow tail
	}
	time.Sleep(time.Duration(latency) * time.Millisecond)

	// Simulate failure
	if rand.Float64() < failureRate {
		logger.Error("payment_declined",
			"amount_cents", req.AmountCents,
			"customer_email", req.CustomerEmail,
			"latency_ms", latency,
			"reason", randomDeclineReason(),
		)
		w.WriteHeader(http.StatusPaymentRequired)
		w.Write([]byte(`{"status":"declined"}`))
		return
	}

	resp := ChargeResponse{
		PaymentID:   fmt.Sprintf("pay_%d", time.Now().UnixNano()),
		AmountCents: req.AmountCents,
		Status:      "succeeded",
	}
	logger.Info("payment_succeeded",
		"payment_id", resp.PaymentID,
		"amount_cents", req.AmountCents,
		"customer_email", req.CustomerEmail,
		"latency_ms", latency,
	)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func randomDeclineReason() string {
	reasons := []string{"insufficient_funds", "card_expired", "fraud_suspected", "issuer_unavailable"}
	return reasons[rand.Intn(len(reasons))]
}

func parseFloatEnv(key string, def float64) float64 {
	if v := os.Getenv(key); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}

func parseIntEnv(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return def
}
