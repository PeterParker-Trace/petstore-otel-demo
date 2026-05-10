// otel.go — OpenTelemetry SDK setup for the payments service.
// Read OTEL_* env vars, build providers (traces/metrics/logs), wire them into globals.
//
// Why a separate file? Keeps the boilerplate out of main.go so the business
// logic stays readable. In Go, OTEL setup is more verbose than in Python/Node
// because Go can't monkey-patch at runtime — providers are configured explicitly.

package main

import (
	"context"
	"fmt"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/log/global"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// initOTel sets up traces, metrics, and logs providers.
// Returns a shutdown function the caller must defer to flush buffered telemetry.
//
// Note: this function reads OTEL_* environment variables automatically because
// the OTLP exporter constructors honor the OpenTelemetry env var spec.
func initOTel(ctx context.Context) (func(context.Context) error, error) {
	// === Propagator setup — CRITICAL for distributed tracing ===
	// In Go, the default propagator is empty. Without this, otelhttp will create
	// new traces for every incoming request instead of joining the caller's trace.
	// This was the #1 bug catching new Go OTEL users. Always set the propagator.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, // W3C traceparent / tracestate headers (the standard)
		propagation.Baggage{},      // W3C baggage header for cross-service key-value context
	))

	// Resource describes the entity producing telemetry: service.name, version, etc.
	// Constructed from OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES env vars.
	res, err := resource.New(ctx,
		resource.WithFromEnv(),     // pulls OTEL_RESOURCE_ATTRIBUTES
		resource.WithTelemetrySDK(), // adds telemetry.sdk.name etc.
		resource.WithProcess(),
		resource.WithHost(),
	)
	if err != nil {
		return nil, fmt.Errorf("resource init: %w", err)
	}

	// --- Traces ---
	traceExp, err := otlptracehttp.New(ctx) // honors OTEL_EXPORTER_OTLP_ENDPOINT
	if err != nil {
		return nil, fmt.Errorf("trace exporter: %w", err)
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExp),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	// --- Metrics ---
	metricExp, err := otlpmetrichttp.New(ctx)
	if err != nil {
		return nil, fmt.Errorf("metric exporter: %w", err)
	}
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExp)),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	// --- Logs ---
	logExp, err := otlploghttp.New(ctx)
	if err != nil {
		return nil, fmt.Errorf("log exporter: %w", err)
	}
	lp := sdklog.NewLoggerProvider(
		sdklog.WithProcessor(sdklog.NewBatchProcessor(logExp)),
		sdklog.WithResource(res),
	)
	global.SetLoggerProvider(lp)

	// Shutdown closure flushes batches in reverse order on exit.
	shutdown := func(ctx context.Context) error {
		var firstErr error
		for _, fn := range []func(context.Context) error{
			tp.Shutdown, mp.Shutdown, lp.Shutdown,
		} {
			if err := fn(ctx); err != nil && firstErr == nil {
				firstErr = err
			}
		}
		return firstErr
	}
	return shutdown, nil
}
