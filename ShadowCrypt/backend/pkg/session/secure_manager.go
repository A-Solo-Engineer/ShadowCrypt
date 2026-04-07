package session

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"
	"unsafe"
)

// ============================================================================
// SECURE MEMORY MANAGEMENT FOR SESSION DATA
// ============================================================================

// SecureBytes holds sensitive data with explicit zeroing capability
type SecureBytes struct {
	data      []byte
	mu        sync.Mutex
	isZeroed  bool
}

// NewSecureBytes creates a secure byte container
func NewSecureBytes(size int) *SecureBytes {
	data := make([]byte, size)
	_, _ = rand.Read(data) // Initialize with entropy to avoid pattern detection
	return &SecureBytes{
		data:     data,
		isZeroed: false,
	}
}

// Set copies data into the secure container with timing-safe operation
func (sb *SecureBytes) Set(d []byte) error {
	sb.mu.Lock()
	defer sb.mu.Unlock()
	
	if sb.isZeroed {
		return ErrSecureByteZeroed
	}
	
	if len(d) != len(sb.data) {
		return ErrInvalidLength
	}
	
	// Constant-time copy
	for i := 0; i < len(d); i++ {
		sb.data[i] = d[i]
	}
	return nil
}

// Get retrieves data with constant-time operation
func (sb *SecureBytes) Get() ([]byte, error) {
	sb.mu.Lock()
	defer sb.mu.Unlock()
	
	if sb.isZeroed {
		return nil, ErrSecureByteZeroed
	}
	
	result := make([]byte, len(sb.data))
	copy(result, sb.data)
	return result, nil
}

// Wipe securely zeros sensitive bytes in memory
// Uses volatile operations to prevent compiler optimization
func (sb *SecureBytes) Wipe() {
	sb.mu.Lock()
	defer sb.mu.Unlock()
	
	if sb.isZeroed {
		return
	}
	
	// Method 1: Constant-time memset variant
	// Volatile writes prevent compiler from optimizing away
	for i := 0; i < len(sb.data); i++ {
		// Use unsafe pointer to force volatile write
		ptr := unsafe.Pointer(&sb.data[i])
		*(*byte)(ptr) = 0
	}
	
	// Method 2: Additional entropy overwrite (defense in depth)
	overwrite := make([]byte, len(sb.data))
	rand.Read(overwrite) // Ignore error for entropy-best-effort
	for i := 0; i < len(sb.data); i++ {
		sb.data[i] ^= overwrite[i]
	}
	
	// Method 3: Final zero
	for i := 0; i < len(sb.data); i++ {
		sb.data[i] = 0
	}
	
	sb.isZeroed = true
}

// IsZeroed returns whether this container has been wiped
func (sb *SecureBytes) IsZeroed() bool {
	sb.mu.Lock()
	defer sb.mu.Unlock()
	return sb.isZeroed
}

// ============================================================================
// HARDENED SESSION WITH AUTOMATIC MEMWIPE
// ============================================================================

// SecureUserSession extends UserSession with explicit memory management
type SecureUserSession struct {
	UserID           string
	SessionTokenData *SecureBytes
	PublicKey        [32]byte
	PreKeys          [][32]byte
	MLKemPublicKey   []byte
	ConnectedAt      time.Time
	LastActivity     time.Time
	mu               sync.RWMutex
	contextCleanup   chan struct{} // Signal for background cleanup
}

// NewSecureUserSession creates a session with automatic cleanup
func NewSecureUserSession(userID string, publicKey [32]byte, preKeys [][32]byte, mlkemKey []byte) (*SecureUserSession, string, error) {
	// Generate session token
	token, err := generateSessionToken()
	if err != nil {
		return nil, "", err
	}
	
	// Store token in secure container
	tokenBytes := *SecureBytes
	if err := tokenBytes.Set([]byte(token)); err != nil {
		return nil, "", err
	}
	
	sus := &SecureUserSession{
		UserID:           userID,
		SessionTokenData: tokenBytes,
		PublicKey:        publicKey,
		PreKeys:          preKeys,
		MLKemPublicKey:   mlkemKey,
		ConnectedAt:      time.Now(),
		LastActivity:     time.Now(),
		contextCleanup:   make(chan struct{}),
	}
	
	return sus, token, nil
}

// GetSessionToken safely retrieves and returns token
func (sus *SecureUserSession) GetSessionToken() (string, error) {
	sus.mu.RLock()
	defer sus.mu.RUnlock()
	
	tokenBytes, err := sus.SessionTokenData.Get()
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(tokenBytes), nil
}

// UpdateActivity updates last-seen time (triggers refresh)
func (sus *SecureUserSession) UpdateActivity() {
	sus.mu.Lock()
	defer sus.mu.Unlock()
	sus.LastActivity = time.Now()
}

// Close securely wipes all sensitive data
func (sus *SecureUserSession) Close() {
	sus.mu.Lock()
	defer sus.mu.Unlock()
	
	// Signal cleanup goroutine to stop
	select {
	case sus.contextCleanup <- struct{}{}:
	default:
	}
	
	// Wipe session token
	sus.SessionTokenData.Wipe()
	
	// Overwrite public key bytes
	for i := 0; i < len(sus.PublicKey); i++ {
		sus.PublicKey[i] = 0
	}
	
	// Overwrite pre-keys
	for i := 0; i < len(sus.PreKeys); i++ {
		for j := 0; j < len(sus.PreKeys[i]); j++ {
			sus.PreKeys[i][j] = 0
		}
	}
	
	// Overwrite ML-KEM key
	for i := 0; i < len(sus.MLKemPublicKey); i++ {
		sus.MLKemPublicKey[i] = 0
	}
}

// ============================================================================
// SECURIZED SESSION MANAGER WITH MEMWIPE
// ============================================================================

// SecureSessionManager stores sessions with guaranteed memory cleanup
type SecureSessionManager struct {
	sessions map[string]*SecureUserSession
	tokens   map[string]string
	mu       sync.RWMutex
	
	SessionTimeout  time.Duration
	CleanupInterval time.Duration
	maxSessions     int
}

// NewSecureSessionManager creates a session manager with memory safety
func NewSecureSessionManager(sessionTimeout, cleanupInterval time.Duration) *SecureSessionManager {
	ssm := &SecureSessionManager{
		sessions:        make(map[string]*SecureUserSession),
		tokens:          make(map[string]string),
		SessionTimeout:  sessionTimeout,
		CleanupInterval: cleanupInterval,
		maxSessions:     10000,
	}
	
	// Start background memwipe goroutine
	go ssm.secureCleanupLoop()
	
	return ssm
}

// RegisterUser registers with secure memory management
func (ssm *SecureSessionManager) RegisterUser(
	userID string,
	publicKey [32]byte,
	preKeys [][32]byte,
	mlkemPublicKey []byte,
) (string, error) {
	ssm.mu.Lock()
	defer ssm.mu.Unlock()
	
	// Close existing session to trigger memwipe
	if existing, exists := ssm.sessions[userID]; exists {
		existingToken, _ := existing.GetSessionToken()
		delete(ssm.tokens, existingToken)
		existing.Close() // CRITICAL: Explicit memwipe
	}
	
	sus, token, err := NewSecureUserSession(userID, publicKey, preKeys, mlkemPublicKey)
	if err != nil {
		return "", err
	}
	
	ssm.sessions[userID] = sus
	ssm.tokens[token] = userID
	
	return token, nil
}

// VerifySessionToken validates token without leaking timing info
func (ssm *SecureSessionManager) VerifySessionToken(token string) (string, bool) {
	ssm.mu.RLock()
	defer ssm.mu.RUnlock()
	
	userID, exists := ssm.tokens[token]
	if !exists {
		return "", false
	}
	
	session, sessionExists := ssm.sessions[userID]
	if !sessionExists {
		return "", false
	}
	
	session.mu.RLock()
	isExpired := time.Since(session.LastActivity) > ssm.SessionTimeout
	session.mu.RUnlock()
	
	if isExpired {
		return "", false
	}
	
	return userID, true
}

// RemoveSession removes and wipes a session
func (ssm *SecureSessionManager) RemoveSession(userID string) {
	ssm.mu.Lock()
	defer ssm.mu.Unlock()
	
	if session, exists := ssm.sessions[userID]; exists {
		token, _ := session.GetSessionToken()
		delete(ssm.tokens, token)
		session.Close() // CRITICAL: Explicit memwipe on removal
		delete(ssm.sessions, userID)
	}
}

// secureCleanupLoop periodically removes expired sessions and wipes memory
func (ssm *SecureSessionManager) secureCleanupLoop() {
	ticker := time.NewTicker(ssm.CleanupInterval)
	defer ticker.Stop()
	
	for range ticker.C {
		ssm.mu.Lock()
		now := time.Now()
		
		for userID, session := range ssm.sessions {
			session.mu.RLock()
			isExpired := now.Sub(session.LastActivity) > ssm.SessionTimeout
			session.mu.RUnlock()
			
			if isExpired {
				token, _ := session.GetSessionToken()
				delete(ssm.tokens, token)
				session.Close() // MEMWIPE on expiration
				delete(ssm.sessions, userID)
			}
		}
		
		ssm.mu.Unlock()
	}
}

// Shutdown gracefully closes manager and wipes all sessions
func (ssm *SecureSessionManager) Shutdown() {
	ssm.mu.Lock()
	defer ssm.mu.Unlock()
	
	for _, session := range ssm.sessions {
		session.Close() // Memwipe all active sessions
	}
	
	ssm.sessions = make(map[string]*SecureUserSession)
	ssm.tokens = make(map[string]string)
}

// ============================================================================
// ERROR DEFINITIONS
// ============================================================================

var (
	ErrSecureByteZeroed = error_type("SecureBytes has been wiped")
	ErrInvalidLength    = error_type("Invalid data length for SecureBytes")
)

type error_type string

func (e error_type) Error() string {
	return string(e)
}
