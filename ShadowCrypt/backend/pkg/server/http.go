package server

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"time"

	"github.com/shadowcrypt/blindrelay/pkg/routing"
)

// HTTPServer wraps http.Server with proper shutdown handling
type HTTPServer struct {
	server      *http.Server
	router      *routing.MessageRouter
	mux         *http.ServeMux
	liveErrors  chan error
}

// NewHTTPServer initializes the HTTP server with handlers
func NewHTTPServer(addr string, wsServer *WebSocketServer, router *routing.MessageRouter) *HTTPServer {
	mux := http.NewServeMux()
	
	// WebSocket endpoint (blind relay)
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		wsServer.HandleConnect(w, r)
	})
	
	// Health check endpoint
	mux.HandleFunc("/health", handleHealth)
	
	// Readiness probe (detailed health for orchestrators)
	mux.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		handleReady(w, r, router)
	})
	
	// Liveness probe (simple heartbeat)
	mux.HandleFunc("/live", handleLive)
	
	server := &http.Server{
		Addr:           addr,
		Handler:        mux,
		ReadTimeout:    15 * time.Second,
		WriteTimeout:   15 * time.Second,
		IdleTimeout:    60 * time.Second,
		MaxHeaderBytes: 1 << 20, // 1MB
	}
	
	return &HTTPServer{
		server:     server,
		router:     router,
		mux:        mux,
		liveErrors: make(chan error, 1),
	}
}

// Start begins listening for requests
func (hs *HTTPServer) Start() error {
	log.Printf("[INFO] BlindRelay starting on %s", hs.server.Addr)
	
	go func() {
		hs.liveErrors <- hs.server.ListenAndServe()
	}()
	
	return nil
}

// Shutdown gracefully shuts down the server
func (hs *HTTPServer) Shutdown(ctx context.Context) error {
	log.Printf("[INFO] Shutting down HTTP server...")
	
	if err := hs.server.Shutdown(ctx); err != nil {
		return fmt.Errorf("shutdown error: %w", err)
	}
	
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-hs.liveErrors:
		// Goroutine finished
	}
	
	return nil
}

// Errors returns the error channel for long-running errors
func (hs *HTTPServer) Errors() <-chan error {
	return hs.liveErrors
}

// handleHealth returns 200 OK if server is healthy
func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, `{"status":"healthy"}`)
}

// handleReady returns 200 OK if server is ready for traffic (readiness probe)
// Used by Koyeb/Kubernetes to determine if service should receive traffic
func handleReady(w http.ResponseWriter, r *http.Request, router *routing.MessageRouter) {
	// Check if core components are functioning
	metrics := router.BroadcastMetrics()
	
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	
	fmt.Fprintf(w, `{
		"ready":true,
		"active_users":%d,
		"timestamp":%d,
		"version":"1.0.0"
	}`,
		metrics["active_users"],
		metrics["timestamp"],
	)
}

// handleLive returns 200 OK if server is alive (liveness probe)
// Used by Koyeb/Kubernetes to determine if container should be restarted
func handleLive(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, `{"alive":true,"timestamp":%d}`, time.Now().UnixNano())
}

// handleMetrics returns real-time server metrics
func handleMetrics(w http.ResponseWriter, r *http.Request, router *routing.MessageRouter) {
	metrics := router.BroadcastMetrics()
	
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	
	// Simple JSON encoding
	fmt.Fprintf(w, `{"active_users":%d,"timestamp":%d}`,
		metrics["active_users"],
		metrics["timestamp"],
	)
}

// GetListenAddr returns the server's listen address
func (hs *HTTPServer) GetListenAddr() string {
	return hs.server.Addr
}

// GetLocalAddress returns the local IP and port for debugging
func (hs *HTTPServer) GetLocalAddress() (string, error) {
	listener, err := net.Listen("tcp", hs.server.Addr)
	if err != nil {
		return "", err
	}
	defer listener.Close()
	return listener.Addr().String(), nil
}
