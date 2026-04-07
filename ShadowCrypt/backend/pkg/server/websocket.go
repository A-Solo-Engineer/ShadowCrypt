package server

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/shadowcrypt/blindrelay/pkg/routing"
	"github.com/shadowcrypt/blindrelay/pkg/session"
)

// ClientConnection represents an active WebSocket connection
type ClientConnection struct {
	userID       string
	sessionToken string
	conn         *websocket.Conn
	send         chan []byte
	done         chan struct{}
	router       *routing.MessageRouter
	sessionMgr   *session.SessionManager
	mu           sync.Mutex
}

// WebSocketServer wraps HTTP and manages WebSocket connections
type WebSocketServer struct {
	http.Handler
	
	router          *routing.MessageRouter
	sessionMgr      *session.SessionManager
	clients         map[string]*ClientConnection
	clientsMu       sync.RWMutex
	AllowedOrigin   string // CORS origin restriction CRITICAL for security
	
	// Configuration
	ReadTimeout     time.Duration
	WriteTimeout    time.Duration
	MaxMessageSize  int64
	PingInterval    time.Duration
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	CheckOrigin: func(r *http.Request) bool {
		// SECURITY: This will be replaced by server-level check
		// Never allow all origins in production!
		return true
	},
}

// NewWebSocketServer initializes a WebSocket server
func NewWebSocketServer(router *routing.MessageRouter, sessionMgr *session.SessionManager) *WebSocketServer {
	ws := &WebSocketServer{
		router:         router,
		sessionMgr:     sessionMgr,
		clients:        make(map[string]*ClientConnection),
		ReadTimeout:    15 * time.Second,
		WriteTimeout:   15 * time.Second,
		MaxMessageSize: 1024 * 1024, // 1MB max message
		PingInterval:   30 * time.Second,
	}
	
	return ws
}

// HandleConnect upgrades HTTP connection to WebSocket
func (ws *WebSocketServer) HandleConnect(w http.ResponseWriter, r *http.Request) {
	// CRITICAL SECURITY: Validate origin before upgrade
	origin := r.Header.Get("Origin")
	if !ws.isOriginAllowed(origin) {
		log.Printf("[WARN] CORS REJECTED: Origin '%s' not in allowed list", origin)
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	
	// Upgrade connection
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[ERROR] WebSocket upgrade failed: %v", err)
		return
	}
	
	conn.SetReadDeadline(time.Now().Add(ws.ReadTimeout))
	conn.SetWriteDeadline(time.Now().Add(ws.WriteTimeout))
	conn.SetReadLimit(ws.MaxMessageSize)
	
	// Receive initial registration packet
	var registerPacket routing.MessagePacket
	err = conn.ReadJSON(&registerPacket)
	if err != nil {
		log.Printf("[ERROR] Failed to read registration: %v", err)
		conn.WriteMessage(websocket.CloseMessage, []byte("registration_failed"))
		conn.Close()
		return
	}
	
	// Validate registration packet
	if err := routing.ValidatePacket(&registerPacket); err != nil {
		log.Printf("[ERROR] Invalid registration packet: %v", err)
		conn.WriteMessage(websocket.CloseMessage, []byte(fmt.Sprintf("invalid_packet: %s", err)))
		conn.Close()
		return
	}
	
	if registerPacket.Type != "register" {
		log.Printf("[ERROR] Expected registration packet, got: %s", registerPacket.Type)
		conn.WriteMessage(websocket.CloseMessage, []byte("expected_register"))
		conn.Close()
		return
	}
	
	// Extract key exchange data
	if registerPacket.KeyExchange == nil {
		log.Printf("[ERROR] Missing key exchange payload")
		conn.WriteMessage(websocket.CloseMessage, []byte("missing_key_exchange"))
		conn.Close()
		return
	}
	
	userID := registerPacket.FromID
	
	// Register user session in ephemeral memory
	prekeys := make([][32]byte, 0)
	sessionToken, err := ws.sessionMgr.RegisterUser(
		userID,
		registerPacket.KeyExchange.X25519PublicKey,
		prekeys,
		registerPacket.KeyExchange.MLKemPublicKey,
	)
	if err != nil {
		log.Printf("[ERROR] Failed to register session: %v", err)
		conn.WriteMessage(websocket.CloseMessage, []byte("registration_error"))
		conn.Close()
		return
	}
	
	// Create client connection state
	client := &ClientConnection{
		userID:       userID,
		sessionToken: sessionToken,
		conn:         conn,
		send:         make(chan []byte, 50),
		done:         make(chan struct{}),
		router:       ws.router,
		sessionMgr:   ws.sessionMgr,
	}
	
	// Register delivery queue for receiving messages
	ws.router.RegisterDeliveryQueue(userID)
	
	// Track client
	ws.clientsMu.Lock()
	ws.clients[userID] = client
	ws.clientsMu.Unlock()
	
	// Send registration acknowledgment
	response := map[string]interface{}{
		"type":           "register_ack",
		"session_token":  sessionToken,
		"timestamp":      time.Now().UnixNano(),
	}
	conn.WriteJSON(response)
	
	log.Printf("[INFO] Client registered: %s", userID[:16])
	
	// Start read and write pumps
	go client.readPump()
	go client.writePump()
}

// readPump handles incoming messages from client
func (cc *ClientConnection) readPump() {
	defer cc.close()
	
	for {
		var packet routing.MessagePacket
		err := cc.conn.ReadJSON(&packet)
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("[ERROR] WebSocket error: %v", err)
			}
			return
		}
		
		// Update session activity
		cc.sessionMgr.UpdateActivity(cc.userID)
		
		// Validate packet
		if err := routing.ValidatePacket(&packet); err != nil {
			ackError := map[string]interface{}{
				"type":         "error",
				"code":         err.(*routing.PacketError).Code,
				"message":      err.(*routing.PacketError).Message,
				"timestamp":    time.Now().UnixNano(),
			}
			ccJSON, _ := json.Marshal(ackError)
			select {
			case cc.send <- ccJSON:
			case <-cc.done:
				return
			}
			continue
		}
		
		// Handle different packet types
		switch packet.Type {
		case "message":
			// Route message to recipient
			success, shouldRetry, errMsg := cc.router.RouteMessage(&packet)
			
			// Send delivery receipt
			ack := map[string]interface{}{
				"type":         "delivery_status",
				"message_id":   packet.MessageID,
				"status":       "ok",
				"timestamp":    time.Now().UnixNano(),
			}
			
			if !success {
				ack["status"] = "failed"
				if shouldRetry {
					ack["retryable"] = true
				}
				ack["error"] = errMsg
			}
			
			ackJSON, _ := json.Marshal(ack)
			select {
			case cc.send <- ackJSON:
			case <-cc.done:
				return
			}
			
		case "ack":
			// Acknowledgment from recipient - discard (no persistence needed)
			log.Printf("[DEBUG] ACK from %s for message %s", cc.userID[:16], packet.MessageID)
		}
	}
}

// writePump handles outgoing messages to client
func (cc *ClientConnection) writePump() {
	ticker := time.NewTicker(30 * time.Second)
	defer func() {
		ticker.Stop()
		cc.close()
	}()
	
	for {
		select {
		case message, ok := <-cc.send:
			cc.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if !ok {
				// Channel closed
				cc.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			
			if err := cc.conn.WriteMessage(websocket.TextMessage, message); err != nil {
				return
			}
			
		case <-ticker.C:
			cc.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := cc.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		
		case <-cc.done:
			return
		}
	}
}

// close gracefully closes the connection
func (cc *ClientConnection) close() {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	
	select {
	case <-cc.done:
		return
	default:
		close(cc.done)
		close(cc.send)
		cc.conn.Close()
	}
	
	// Unregister from router and session manager
	cc.router.UnregisterDeliveryQueue(cc.userID)
	cc.sessionMgr.RemoveSession(cc.userID)
	
	// Remove from tracked clients
	// Note: This operation happens in server context, not here
}

// isOriginAllowed validates CORS origin against allowed list
// CRITICAL: Prevents open relay vulnerability
func (ws *WebSocketServer) isOriginAllowed(origin string) bool {
	// Wildcard allows all origins (for development only)
	if ws.AllowedOrigin == "*" {
		log.Printf("[WARN] CORS: Wildcard origin allowed (development mode)")
		return true
	}
	
	// Empty origin means no CORS headers (same-origin requests)
	if origin == "" {
		return true
	}
	
	// Exact match required
	if origin == ws.AllowedOrigin {
		return true
	}
	
	// No match - origin is NOT allowed
	return false
}

// ServeHTTP implements http.Handler for the WebSocket endpoint
func (ws *WebSocketServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	
	ws.HandleConnect(w, r)
}

// ListClients returns active client userIDs
func (ws *WebSocketServer) ListClients() []string {
	ws.clientsMu.RLock()
	defer ws.clientsMu.RUnlock()
	
	clients := make([]string, 0, len(ws.clients))
	for userID := range ws.clients {
		clients = append(clients, userID)
	}
	return clients
}

// GetClientCount returns number of connected clients
func (ws *WebSocketServer) GetClientCount() int {
	ws.clientsMu.RLock()
	defer ws.clientsMu.RUnlock()
	return len(ws.clients)
}
