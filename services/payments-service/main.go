// payments-service: simulates a payment gateway with intentional chaos.
// Now instrumented with OpenTelemetry traces, metrics, and logs.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	otelslog "go.opentelemetry.io/contrib/bridges/otelslog"
)

// NOTE: Add the otelslog import path to go.mod via `go get` during build.
// Listed separately because some IDE tooling pulls it implicitly.

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
	failureRate float64
	maxLatency  int
)

func main() {
	ctx := context.Background()

	// Initialize OTEL FIRST, before anything else logs or makes HTTP calls.
	shutdown, err := initOTel(ctx)
	if err != nil {
		// Use stdlib log here since our slog isn't built yet.
		fmt.Fprintf(os.Stderr, "OTEL init failed: %v\n", err)
		os.Exit(1)
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = shutdown(shutdownCtx)
	}()

	// slog with the OTEL bridge: every log line goes both to stdout (JSON)
	// AND to the OTEL log pipeline (which the Collector receives).
	// We use a multi-handler approach via Tee'd handlers below.
	stdoutHandler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})
	otelHandler := otelslog.NewHandler("payments-service")
	logger = slog.New(teeHandler{stdoutHandler, otelHandler})

	failureRate = parseFloatEnv("FAILURE_RATE", 0.10)
	maxLatency = parseIntEnv("MAX_LATENCY_MS", 800)

	logger.Info("payments_service_starting", "failure_rate", failureRate, "max_latency_ms", maxLatency)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/charge", chargeHandler)

	// otelhttp.NewHandler wraps the mux to automatically create server spans
	// for every incoming request.
	instrumented := otelhttp.NewHandler(mux, "payments-service")

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	logger.Info("payments_service_listening", "port", port)
	if err := http.ListenAndServe(":"+port, instrumented); err != nil {
		logger.Error("server_failed", "err", err)
		os.Exit(1)
	}
}

// teeHandler sends every record to two slog handlers. Lets us write to
// stdout AND export via OTEL simultaneously.
type teeHandler struct {
	a, b slog.Handler
}

func (t teeHandler) Enabled(ctx context.Context, l slog.Level) bool {
	return t.a.Enabled(ctx, l) || t.b.Enabled(ctx, l)
}
func (t teeHandler) Handle(ctx context.Context, r slog.Record) error {
	_ = t.a.Handle(ctx, r.Clone())
	return t.b.Handle(ctx, r)
}
func (t teeHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return teeHandler{t.a.WithAttrs(attrs), t.b.WithAttrs(attrs)}
}
func (t teeHandler) WithGroup(name string) slog.Handler {
	return teeHandler{t.a.WithGroup(name), t.b.WithGroup(name)}
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
		logger.WarnContext(r.Context(), "invalid_charge_request", "err", err)
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	latency := 50 + rand.Intn(maxLatency)
	if rand.Float64() < 0.05 {
		latency += 1500 + rand.Intn(2000)
	}
	time.Sleep(time.Duration(latency) * time.Millisecond)

	if rand.Float64() < failureRate {
		// WarnContext / ErrorContext use the request's context, which carries
		// the trace_id from otelhttp. This is the magic that links logs to traces.
		logger.ErrorContext(r.Context(), "payment_declined",
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
	logger.InfoContext(r.Context(), "payment_succeeded",
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
