package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/shadowcrypt/blindrelay/pkg/routing"
	"github.com/shadowcrypt/blindrelay/pkg/server"
	"github.com/shadowcrypt/blindrelay/pkg/session"
)

// BuildInfo stores version information for deployment tracking
var (
	BuildVersion = "dev"
	BuildTime    = "unknown"
	BuildCommit  = "unknown"
)

func main() {
	// CLI flags with defaults
	addr := flag.String("addr", "", "Listen address (host:port), override with $PORT")
	sessionTimeout := flag.Duration("session-timeout", 0, "Session timeout duration, override with $SESSION_TIMEOUT_MINUTES")
	cleanupInterval := flag.Duration("cleanup-interval", 0, "Session cleanup interval, override with $CLEANUP_INTERVAL_MINUTES")
	allowedOrigin := flag.String("allowed-origin", "", "Allowed WebSocket origin, override with $ALLOWED_ORIGIN")
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.Lshortfile)
	log.Printf("[INFO] BlindRelay Server v%s starting (commit: %s, built: %s)\n", 
		BuildVersion, BuildCommit, BuildTime)

	// Load configuration from environment variables (production-first)
	config := loadConfig(addr, sessionTimeout, cleanupInterval, allowedOrigin)
	log.Printf("[INFO] Configuration loaded: addr=%s, sessionTimeout=%v, allowedOrigin=%s\n",
		config.Addr, config.SessionTimeout, config.AllowedOrigin)

	// Load configuration from environment variables (production-first)
	config := loadConfig(addr, sessionTimeout, cleanupInterval, allowedOrigin)
	log.Printf("[INFO] Configuration loaded: addr=%s, sessionTimeout=%v, allowedOrigin=%s\n",
		config.Addr, config.SessionTimeout, config.AllowedOrigin)

	// Initialize core components
	sessionMgr := session.NewSessionManager(config.SessionTimeout, config.CleanupInterval)
	router := routing.NewMessageRouter(sessionMgr)
	wsServer := server.NewWebSocketServer(router, sessionMgr)
	wsServer.AllowedOrigin = config.AllowedOrigin // Set CORS origin
	httpServer := server.NewHTTPServer(config.Addr, wsServer, router)

	// Start HTTP server
	if err := httpServer.Start(); err != nil {
		log.Fatalf("[FATAL] Failed to start server: %v", err)
	}

	log.Printf("[INFO] Server running on %s\n", config.Addr)

	// Handle graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-httpServer.Errors():
		log.Printf("[ERROR] Server error: %v", err)
	case sig := <-sigChan:
		log.Printf("[INFO] Received signal: %v", sig)
	}

	// Graceful shutdown with timeout
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Printf("[ERROR] Shutdown error: %v", err)
	}

	log.Printf("[INFO] Server stopped")
}

// ServerConfig holds all production configuration from environment/flags
type ServerConfig struct {
	Addr             string
	SessionTimeout   time.Duration
	CleanupInterval  time.Duration
	AllowedOrigin    string
	RateLimitPerSec  int
	MaxConnections   int
}

// loadConfig loads configuration from environment variables with fallbacks
func loadConfig(addrFlag *string, timeoutFlag, cleanupFlag *time.Duration, originFlag *string) ServerConfig {
	config := ServerConfig{
		// Defaults
		Addr:            ":3000",
		SessionTimeout:  60 * time.Minute,
		CleanupInterval: 5 * time.Minute,
		AllowedOrigin:   "http://localhost:3000",
		RateLimitPerSec: 1000,
		MaxConnections:  10000,
	}

	// Override from $PORT environment variable (Koyeb standard)
	if port := os.Getenv("PORT"); port != "" {
		config.Addr = ":" + port
		log.Printf("[INFO] Using PORT from environment: %s", port)
	} else if *addrFlag != "" {
		config.Addr = *addrFlag
	}

	// Override from $SESSION_TIMEOUT_MINUTES
	if timeout := os.Getenv("SESSION_TIMEOUT_MINUTES"); timeout != "" {
		if minutes, err := strconv.Atoi(timeout); err == nil {
			config.SessionTimeout = time.Duration(minutes) * time.Minute
			log.Printf("[INFO] Using SESSION_TIMEOUT_MINUTES from environment: %d min", minutes)
		}
	} else if *timeoutFlag > 0 {
		config.SessionTimeout = *timeoutFlag
	}

	// Override from $CLEANUP_INTERVAL_MINUTES
	if cleanup := os.Getenv("CLEANUP_INTERVAL_MINUTES"); cleanup != "" {
		if minutes, err := strconv.Atoi(cleanup); err == nil {
			config.CleanupInterval = time.Duration(minutes) * time.Minute
			log.Printf("[INFO] Using CLEANUP_INTERVAL_MINUTES from environment: %d min", minutes)
		}
	} else if *cleanupFlag > 0 {
		config.CleanupInterval = *cleanupFlag
	}

	// Override from $ALLOWED_ORIGIN (CRITICAL for security)
	if origin := os.Getenv("ALLOWED_ORIGIN"); origin != "" {
		config.AllowedOrigin = origin
		log.Printf("[INFO] Using ALLOWED_ORIGIN from environment: %s", origin)
	} else if *originFlag != "" {
		config.AllowedOrigin = *originFlag
	}

	// Override from $RATE_LIMIT_PER_SEC
	if rateLimit := os.Getenv("RATE_LIMIT_PER_SEC"); rateLimit != "" {
		if limit, err := strconv.Atoi(rateLimit); err == nil {
			config.RateLimitPerSec = limit
		}
	}

	// Override from $MAX_CONNECTIONS
	if maxConns := os.Getenv("MAX_CONNECTIONS"); maxConns != "" {
		if max, err := strconv.Atoi(maxConns); err == nil {
			config.MaxConnections = max
		}
	}

	// Validate critical configuration
	if config.AllowedOrigin == "" {
		log.Printf("[WARN] ⚠️  ALLOWED_ORIGIN is empty - WebSocket will accept ANY origin!")
		config.AllowedOrigin = "*" // Fallback, but log warning
	}

	log.Printf("[INFO] Configuration Summary:")
	log.Printf("      Addr: %s", config.Addr)
	log.Printf("      SessionTimeout: %v", config.SessionTimeout)
	log.Printf("      CleanupInterval: %v", config.CleanupInterval)
	log.Printf("      AllowedOrigin: %s", config.AllowedOrigin)
	log.Printf("      RateLimitPerSec: %d", config.RateLimitPerSec)
	log.Printf("      MaxConnections: %d", config.MaxConnections)

	return config
