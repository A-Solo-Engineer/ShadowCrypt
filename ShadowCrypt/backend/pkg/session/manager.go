package session

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"
)

// UserSession represents an ephemeral user connection in RAM
type UserSession struct {
	UserID        string    // Ed25519 public key as hex string
	SessionToken  string    // Random session token
	PublicKey     [32]byte  // Ed25519 public key bytes
	PreKeys       [][32]byte // X25519 prekeys for key exchange
	MLKemPublicKey []byte   // ML-KEM-768 public key (post-quantum)
	ConnectedAt   time.Time
	LastActivity  time.Time
	mutex         sync.RWMutex
}

// SessionManager stores all active user sessions in ephemeral RAM
type SessionManager struct {
	sessions map[string]*UserSession // userID -> UserSession
	tokens   map[string]string        // sessionToken -> userID (reverse lookup)
	mu       sync.RWMutex
	
	// Configuration
	SessionTimeout    time.Duration
	CleanupInterval   time.Duration
	maxSessionsPerUser int
}

// NewSessionManager initializes an ephemeral session manager
func NewSessionManager(sessionTimeout, cleanupInterval time.Duration) *SessionManager {
	sm := &SessionManager{
		sessions:          make(map[string]*UserSession),
		tokens:            make(map[string]string),
		SessionTimeout:    sessionTimeout,
		CleanupInterval:   cleanupInterval,
		maxSessionsPerUser: 1, // One session per user for simplicity
	}
	
	// Start background cleanup goroutine
	go sm.cleanupExpiredSessions()
	
	return sm
}

// RegisterUser registers a new user session with their Ed25519 public key
func (sm *SessionManager) RegisterUser(userID string, publicKey [32]byte, preKeys [][32]byte, mlkemPublicKey []byte) (string, error) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	
	// Check if user already has an active session
	if existing, exists := sm.sessions[userID]; exists {
		// Invalidate old session token
		delete(sm.tokens, existing.SessionToken)
	}
	
	// Generate secure session token
	token, err := generateSessionToken()
	if err != nil {
		return "", err
	}
	
	session := &UserSession{
		UserID:         userID,
		SessionToken:   token,
		PublicKey:      publicKey,
		PreKeys:        preKeys,
		MLKemPublicKey: mlkemPublicKey,
		ConnectedAt:    time.Now(),
		LastActivity:   time.Now(),
	}
	
	sm.sessions[userID] = session
	sm.tokens[token] = userID
	
	return token, nil
}

// GetSession retrieves a user session by UserID
func (sm *SessionManager) GetSession(userID string) (*UserSession, bool) {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	
	session, exists := sm.sessions[userID]
	if !exists {
		return nil, false
	}
	
	// Check if session has expired
	if time.Since(session.LastActivity) > sm.SessionTimeout {
		return nil, false
	}
	
	return session, true
}

// VerifySessionToken validates a session token and returns the associated userID
func (sm *SessionManager) VerifySessionToken(token string) (string, bool) {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	
	userID, exists := sm.tokens[token]
	if !exists {
		return "", false
	}
	
	session, sessionExists := sm.sessions[userID]
	if !sessionExists {
		return "", false
	}
	
	// Check if session has expired
	if time.Since(session.LastActivity) > sm.SessionTimeout {
		return "", false
	}
	
	return userID, true
}

// UpdateActivity records that a session had recent activity
func (sm *SessionManager) UpdateActivity(userID string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	
	if session, exists := sm.sessions[userID]; exists {
		session.mutex.Lock()
		session.LastActivity = time.Now()
		session.mutex.Unlock()
	}
}

// RemoveSession removes a user session
func (sm *SessionManager) RemoveSession(userID string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	
	if session, exists := sm.sessions[userID]; exists {
		delete(sm.tokens, session.SessionToken)
		delete(sm.sessions, userID)
	}
}

// cleanupExpiredSessions periodically removes expired sessions from memory
func (sm *SessionManager) cleanupExpiredSessions() {
	ticker := time.NewTicker(sm.CleanupInterval)
	defer ticker.Stop()
	
	for range ticker.C {
		sm.mu.Lock()
		now := time.Now()
		
		for userID, session := range sm.sessions {
			if now.Sub(session.LastActivity) > sm.SessionTimeout {
				delete(sm.tokens, session.SessionToken)
				delete(sm.sessions, userID)
			}
		}
		
		sm.mu.Unlock()
	}
}

// ListActiveSessions returns count of active sessions (for monitoring)
func (sm *SessionManager) ListActiveSessions() int {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return len(sm.sessions)
}

// generateSessionToken creates a cryptographically secure random session token
func generateSessionToken() (string, error) {
	b := make([]byte, 32)
	_, err := rand.Read(b)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
