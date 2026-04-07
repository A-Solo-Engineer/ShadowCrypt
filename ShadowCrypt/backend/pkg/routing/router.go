package routing

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/shadowcrypt/blindrelay/pkg/session"
)

// MessagePacket represents the wire-format message between clients
type MessagePacket struct {
	Type         string    `json:"type"`              // "register", "message", "ack", "key-exchange"
	FromID       string    `json:"from_id"`           // Sender's Ed25519 public key (hex)
	ToID         string    `json:"to_id"`             // Recipient's Ed25519 public key (hex)
	SessionToken string    `json:"session_token"`     // Authentication token
	Payload      string    `json:"payload"`           // Encrypted message (base64)
	Timestamp    int64     `json:"timestamp"`         // Unix nanoseconds
	MessageID    string    `json:"message_id"`        // Unique message ID for correlation
	KeyExchange  *KeyExchangePayload `json:"key_exchange,omitempty"` // For initial handshake
}

// KeyExchangePayload contains X25519 and ML-KEM-768 public keys
type KeyExchangePayload struct {
	X25519PublicKey [32]byte `json:"x25519_public_key"` // For ECDHE
	MLKemPublicKey  []byte   `json:"mlkem_public_key"`  // Post-quantum
	PreKeys         []string `json:"pre_keys"`          // Array of prekeys (for future use)
}

// DeliveryQueue holds pending messages for a user
type DeliveryQueue struct {
	UserID   string
	Messages chan *MessagePacket
	Closed   bool
	mu       sync.Mutex
}

// MessageRouter handles blind relaying without storing messages to disk
type MessageRouter struct {
	// Active delivery queues per connected user
	queues map[string]*DeliveryQueue
	mu     sync.RWMutex
	
	// Session manager reference (for validation)
	sessionMgr *session.SessionManager
	
	// Configuration
	MaxQueueSize    int
	MessageTimeout  time.Duration
	NackOnUnroutable bool
}

// NewMessageRouter initializes a router
func NewMessageRouter(sessionMgr *session.SessionManager) *MessageRouter {
	return &MessageRouter{
		queues:          make(map[string]*DeliveryQueue),
		sessionMgr:      sessionMgr,
		MaxQueueSize:    100,
		MessageTimeout:  30 * time.Second,
		NackOnUnroutable: true,
	}
}

// RegisterDeliveryQueue creates a queue for incoming messages to a connected client
func (mr *MessageRouter) RegisterDeliveryQueue(userID string) *DeliveryQueue {
	mr.mu.Lock()
	defer mr.mu.Unlock()
	
	// Close existing queue if present
	if existing, exists := mr.queues[userID]; exists {
		existing.mu.Lock()
		if !existing.Closed {
			close(existing.Messages)
			existing.Closed = true
		}
		existing.mu.Unlock()
	}
	
	queue := &DeliveryQueue{
		UserID:   userID,
		Messages: make(chan *MessagePacket, mr.MaxQueueSize),
		Closed:   false,
	}
	
	mr.queues[userID] = queue
	return queue
}

// UnregisterDeliveryQueue removes a user's delivery queue
func (mr *MessageRouter) UnregisterDeliveryQueue(userID string) {
	mr.mu.Lock()
	defer mr.mu.Unlock()
	
	if queue, exists := mr.queues[userID]; exists {
		queue.mu.Lock()
		if !queue.Closed {
			close(queue.Messages)
			queue.Closed = true
		}
		queue.mu.Unlock()
		delete(mr.queues, userID)
	}
}

// RouteMessage performs blind message relaying from sender to recipient
// Returns (success, shouldRetry, errorMessage)
func (mr *MessageRouter) RouteMessage(packet *MessagePacket) (bool, bool, string) {
	// Validate sender's session
	_, valid := mr.sessionMgr.VerifySessionToken(packet.SessionToken)
	if !valid {
		return false, false, "invalid_session_token"
	}
	
	// Update sender's activity
	mr.sessionMgr.UpdateActivity(packet.FromID)
	
	// Get recipient's delivery queue
	mr.mu.RLock()
	queue, exists := mr.queues[packet.ToID]
	mr.mu.RUnlock()
	
	if !exists {
		// Recipient not currently connected
		if mr.NackOnUnroutable {
			return false, true, "recipient_offline"
		}
		return false, false, "recipient_offline"
	}
	
	// Attempt non-blocking send to recipient's queue
	select {
	case queue.Messages <- packet:
		// Successfully queued for delivery
		return true, false, ""
	case <-time.After(100 * time.Millisecond):
		// Queue full or slow recipient - transient failure
		return false, true, "recipient_queue_full"
	}
}

// GetDeliveryQueue retrieves a user's message queue
func (mr *MessageRouter) GetDeliveryQueue(userID string) (*DeliveryQueue, bool) {
	mr.mu.RLock()
	defer mr.mu.RUnlock()
	
	queue, exists := mr.queues[userID]
	return queue, exists
}

// BroadcastMetrics returns real-time server metrics (for monitoring)
func (mr *MessageRouter) BroadcastMetrics() map[string]interface{} {
	mr.mu.RLock()
	defer mr.mu.RUnlock()
	
	metrics := make(map[string]interface{})
	metrics["active_users"] = len(mr.queues)
	metrics["timestamp"] = time.Now().UnixNano()
	
	return metrics
}

// DrainQueue empties a delivery queue and discards all messages
func (mr *MessageRouter) DrainQueue(userID string) int {
	mr.mu.RLock()
	queue, exists := mr.queues[userID]
	mr.mu.RUnlock()
	
	if !exists {
		return 0
	}
	
	count := 0
	queue.mu.Lock()
	defer queue.mu.Unlock()
	
	for {
		select {
		case <-queue.Messages:
			count++
		default:
			return count
		}
	}
}

// ValidatePacket performs basic validation on incoming packets
func ValidatePacket(packet *MessagePacket) error {
	if packet.Type == "" {
		return NewPacketError("invalid_type", "message type is required")
	}
	
	switch packet.Type {
	case "register":
		if packet.FromID == "" {
			return NewPacketError("invalid_from_id", "from_id is required for registration")
		}
		if packet.KeyExchange == nil {
			return NewPacketError("missing_key_exchange", "key exchange payload required for registration")
		}
	case "message":
		if packet.FromID == "" {
			return NewPacketError("invalid_from_id", "from_id is required")
		}
		if packet.ToID == "" {
			return NewPacketError("invalid_to_id", "to_id is required")
		}
		if packet.Payload == "" {
			return NewPacketError("empty_payload", "message payload cannot be empty")
		}
	case "ack":
		if packet.MessageID == "" {
			return NewPacketError("invalid_ack", "message_id required for acknowledgment")
		}
	default:
		return NewPacketError("unknown_type", "unsupported message type")
	}
	
	return nil
}

// PacketError represents validation errors
type PacketError struct {
	Code    string
	Message string
}

func NewPacketError(code, message string) *PacketError {
	return &PacketError{Code: code, Message: message}
}

func (pe *PacketError) Error() string {
	return pe.Code + ": " + pe.Message
}

// ParsePacket unmarshals JSON into a MessagePacket
func ParsePacket(data []byte) (*MessagePacket, error) {
	var packet MessagePacket
	if err := json.Unmarshal(data, &packet); err != nil {
		return nil, NewPacketError("parse_error", err.Error())
	}
	return &packet, nil
}
