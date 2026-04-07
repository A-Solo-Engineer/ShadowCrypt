package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"sync"
	"time"

	"golang.org/x/crypto/ed25519"
)

// ============================================================================
// CHALLENGE RESPONSE AUTHENTICATION
// ============================================================================

// Challenge represents a server-issued cryptographic challenge
type Challenge struct {
	ID        string    // Unique challenge identifier
	Nonce     []byte    // Random 32-byte nonce
	IssuedAt  int64     // Unix timestamp in nanoseconds
	ExpiresAt int64     // Unix timestamp in nanoseconds
	Status    string    // "pending", "verified", "rejected", "expired"
	ClientID  string    // The public key attempting to register
}

// ChallengeResponse is the client's answer to a challenge
type ChallengeResponse struct {
	ChallengeID string // Reference to Challenge.ID
	Signature   []byte // Ed25519(nonce, client_private_key)
	PublicKey   []byte // Client's Ed25519 public key (must match registration request)
	Timestamp   int64  // Client-side timestamp
}

// VerifiedIdentity represents a successfully verified user identity
type VerifiedIdentity struct {
	PublicKey     []byte    // Ed25519 public key
	VerifiedAt    int64     // Unix timestamp when identity was verified
	ChallengeID   string    // The challenge that was answered
	IPAddress     string    // IP address of registration request
	UserAgent     string    // HTTP User-Agent of registration request
	ExpiresAt     int64     // Identity verification expires (to prevent token reuse)
}

// ChallengeStore manages challenges in memory with automatic expiration
type ChallengeStore struct {
	mu         sync.RWMutex
	challenges map[string]*Challenge
	ttl        time.Duration
	maxAge     int64
}

// NewChallengeStore creates a new challenge store with TTL-based cleanup
func NewChallengeStore(ttl time.Duration) *ChallengeStore {
	store := &ChallengeStore{
		challenges: make(map[string]*Challenge),
		ttl:        ttl,
		maxAge:     int64(ttl.Nanoseconds()),
	}

	// Background cleanup goroutine
	go store.cleanupExpiredChallenges()

	return store
}

// IssueChallenge creates a new cryptographic challenge for a registration attempt
// clientPublicKey: The Ed25519 public key attempting to register
// Returns: Challenge nonce that client must sign, or error
func (cs *ChallengeStore) IssueChallenge(clientPublicKey []byte) (*Challenge, error) {
	if len(clientPublicKey) != ed25519.PublicKeySize {
		return nil, errors.New("invalid public key size")
	}

	// Generate random 32-byte nonce
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("failed to generate nonce: %w", err)
	}

	now := time.Now()
	challengeID := base64.URLEncoding.EncodeToString(nonce) // Use nonce as ID for quick lookup

	challenge := &Challenge{
		ID:        challengeID,
		Nonce:     nonce,
		IssuedAt:  now.UnixNano(),
		ExpiresAt: now.Add(cs.ttl).UnixNano(),
		Status:    "pending",
		ClientID:  base64.URLEncoding.EncodeToString(clientPublicKey),
	}

	cs.mu.Lock()
	cs.challenges[challengeID] = challenge
	cs.mu.Unlock()

	return challenge, nil
}

// VerifyChallenge validates that the client correctly signed the challenge nonce
// Returns: VerifiedIdentity on success, or error with rejection reason
func (cs *ChallengeStore) VerifyChallenge(
	response ChallengeResponse,
	ipAddress string,
	userAgent string,
) (*VerifiedIdentity, error) {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	challenge, exists := cs.challenges[response.ChallengeID]
	if !exists {
		return nil, errors.New("challenge not found")
	}

	// Check challenge expiration
	if time.Now().UnixNano() > challenge.ExpiresAt {
		challenge.Status = "expired"
		return nil, errors.New("challenge expired (TTL exceeded)")
	}

	// Check if challenge already answered
	if challenge.Status != "pending" {
		return nil, fmt.Errorf("challenge already processed: %s", challenge.Status)
	}

	// Validate public key size
	if len(response.PublicKey) != ed25519.PublicKeySize {
		challenge.Status = "rejected"
		return nil, errors.New("invalid public key size")
	}

	// CRITICAL: Verify Ed25519 signature
	if !ed25519.Verify(response.PublicKey, challenge.Nonce, response.Signature) {
		challenge.Status = "rejected"

		// Log the failed attempt (for intrusion detection)
		fmt.Printf(
			"❌ SECURITY: Failed Ed25519 signature verification. IP: %s, Key: %s\n",
			ipAddress,
			base64.URLEncoding.EncodeToString(response.PublicKey),
		)

		return nil, errors.New("ed25519 signature verification failed")
	}

	// Public key must match the one requested in registration
	requestedKey := base64.URLEncoding.EncodeToString(response.PublicKey)
	if requestedKey != challenge.ClientID {
		challenge.Status = "rejected"
		return nil, errors.New("public key mismatch: signature key != registration key")
	}

	// Signature valid! Mark challenge as verified
	challenge.Status = "verified"

	// Create verified identity (good for 30 minutes, prevents token reuse)
	verifiedIdentity := &VerifiedIdentity{
		PublicKey:   response.PublicKey,
		VerifiedAt:  time.Now().UnixNano(),
		ChallengeID: response.ChallengeID,
		IPAddress:   ipAddress,
		UserAgent:   userAgent,
		ExpiresAt:   time.Now().Add(30 * time.Minute).UnixNano(),
	}

	fmt.Printf(
		"✅ SECURITY: Ed25519 signature verified. IP: %s, Key: %s\n",
		ipAddress,
		base64.URLEncoding.EncodeToString(response.PublicKey),
	)

	return verifiedIdentity, nil
}

// RejectChallenge manually rejects a challenge (e.g., after rate limiting)
func (cs *ChallengeStore) RejectChallenge(challengeID string, reason string) error {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	challenge, exists := cs.challenges[challengeID]
	if !exists {
		return errors.New("challenge not found")
	}

	challenge.Status = "rejected"
	fmt.Printf("⚠️  Challenge rejected: %s\n", reason)

	return nil
}

// GetChallenge retrieves a challenge for status checking
func (cs *ChallengeStore) GetChallenge(challengeID string) (*Challenge, error) {
	cs.mu.RLock()
	defer cs.mu.RUnlock()

	challenge, exists := cs.challenges[challengeID]
	if !exists {
		return nil, errors.New("challenge not found")
	}

	return challenge, nil
}

// cleanupExpiredChallenges removes expired challenges every 30 seconds
func (cs *ChallengeStore) cleanupExpiredChallenges() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		cs.mu.Lock()

		now := time.Now().UnixNano()
		removed := 0

		for id, challenge := range cs.challenges {
			// Keep challenges that are 'pending' but allow some grace period for network latency
			if challenge.ExpiresAt < now {
				delete(cs.challenges, id)
				removed++
			}
		}

		cs.mu.Unlock()

		if removed > 0 {
			fmt.Printf("🧹 Cleaned up %d expired challenges\n", removed)
		}
	}
}

// ============================================================================
// REPLAY ATTACK PREVENTION
// ============================================================================

// RegistrationAttemptTracker prevents replay attacks and brute force
type RegistrationAttemptTracker struct {
	mu       sync.RWMutex
	attempts map[string][]*RegistrationAttempt
	maxAttempts int
	windowDuration time.Duration
}

// RegistrationAttempt represents one attempt to register a key
type RegistrationAttempt struct {
	PublicKey string
	Timestamp int64
	Success   bool
	IPAddress string
}

// NewRegistrationAttemptTracker creates tracker for brute force prevention
func NewRegistrationAttemptTracker(maxAttempts int, window time.Duration) *RegistrationAttemptTracker {
	return &RegistrationAttemptTracker{
		attempts: make(map[string][]*RegistrationAttempt),
		maxAttempts: maxAttempts,
		windowDuration: window,
	}
}

// RecordAttempt logs a registration attempt
func (rat *RegistrationAttemptTracker) RecordAttempt(
	publicKey string,
	success bool,
	ipAddress string,
) error {
	rat.mu.Lock()
	defer rat.mu.Unlock()

	key := publicKey

	// Create key bucket if not exists
	if _, exists := rat.attempts[key]; !exists {
		rat.attempts[key] = []*RegistrationAttempt{}
	}

	// Add attempt
	now := time.Now().UnixNano()
	rat.attempts[key] = append(rat.attempts[key], &RegistrationAttempt{
		PublicKey: publicKey,
		Timestamp: now,
		Success:   success,
		IPAddress: ipAddress,
	})

	// Clean old attempts outside window
	windowStart := now - int64(rat.windowDuration.Nanoseconds())
	filtered := []*RegistrationAttempt{}
	for _, attempt := range rat.attempts[key] {
		if attempt.Timestamp > windowStart {
			filtered = append(filtered, attempt)
		}
	}
	rat.attempts[key] = filtered

	// Check rate limit
	if len(rat.attempts[key]) > rat.maxAttempts {
		return fmt.Errorf("registration rate limit exceeded: %d attempts in %v", 
			len(rat.attempts[key]), rat.windowDuration)
	}

	return nil
}

// IsAllowed checks if key has remaining registration attempts
func (rat *RegistrationAttemptTracker) IsAllowed(publicKey string) bool {
	rat.mu.RLock()
	defer rat.mu.RUnlock()

	attempts, exists := rat.attempts[publicKey]
	if !exists {
		return true
	}

	now := time.Now().UnixNano()
	windowStart := now - int64(rat.windowDuration.Nanoseconds())

	recentAttempts := 0
	for _, attempt := range attempts {
		if attempt.Timestamp > windowStart {
			recentAttempts++
		}
	}

	return recentAttempts < rat.maxAttempts
}

// ============================================================================
// REGISTRATION FLOW HANDLER
// ============================================================================

// RegistrationHandler processes the complete registration challenge-response flow
type RegistrationHandler struct {
	challengeStore      *ChallengeStore
	attemptTracker      *RegistrationAttemptTracker
	verifiedIdentities  map[string]*VerifiedIdentity
	identitiesMu        sync.RWMutex
}

// NewRegistrationHandler creates a new registration handler
func NewRegistrationHandler() *RegistrationHandler {
	return &RegistrationHandler{
		challengeStore:     NewChallengeStore(5 * time.Minute),
		attemptTracker:     NewRegistrationAttemptTracker(10, 15*time.Minute), // 10 attempts per 15 min
		verifiedIdentities: make(map[string]*VerifiedIdentity),
	}
}

// Step1_RequestChallenge initiates registration by issuing a challenge
// Returns: Challenge nonce (send to client for signing)
func (rh *RegistrationHandler) Step1_RequestChallenge(
	publicKey []byte,
	ipAddress string,
) (*Challenge, error) {
	keyStr := base64.URLEncoding.EncodeToString(publicKey)

	// Check rate limit
	if !rh.attemptTracker.IsAllowed(keyStr) {
		return nil, errors.New("registration rate limited: too many attempts")
	}

	// Issue challenge
	challenge, err := rh.challengeStore.IssueChallenge(publicKey)
	if err != nil {
		return nil, err
	}

	fmt.Printf(
		"📝 Challenge issued for key: %s... (from IP: %s)\n",
		keyStr[:16],
		ipAddress,
	)

	return challenge, nil
}

// Step2_SubmitChallengeResponse processes client's signed challenge
// Returns: Session token on success
func (rh *RegistrationHandler) Step2_SubmitChallengeResponse(
	response ChallengeResponse,
	ipAddress string,
	userAgent string,
) (string, error) {
	keyStr := base64.URLEncoding.EncodeToString(response.PublicKey)

	// Verify the challenge
	verified, err := rh.challengeStore.VerifyChallenge(response, ipAddress, userAgent)
	if err != nil {
		// Record failed attempt
		rh.attemptTracker.RecordAttempt(keyStr, false, ipAddress)
		return "", fmt.Errorf("challenge verification failed: %w", err)
	}

	// Record successful attempt
	rh.attemptTracker.RecordAttempt(keyStr, true, ipAddress)

	// Store verified identity
	rh.identitiesMu.Lock()
	rh.verifiedIdentities[keyStr] = verified
	rh.identitiesMu.Unlock()

	// Generate session token (in real system, would be JWT with identity claims)
	sessionToken := rh.generateSessionToken(verified)

	fmt.Printf(
		"🔐 User registered and verified: %s... (Session: %s)\n",
		keyStr[:16],
		sessionToken[:16],
	)

	return sessionToken, nil
}

// generateSessionToken creates a session token for the verified user
func (rh *RegistrationHandler) generateSessionToken(identity *VerifiedIdentity) string {
	// Compute SHA256(publicKey || timestamp || random)
	hash := sha256.New()
	hash.Write(identity.PublicKey)
	hash.Write([]byte(fmt.Sprintf("%d", identity.VerifiedAt)))
	
	randomBytes := make([]byte, 16)
	rand.Read(randomBytes)
	hash.Write(randomBytes)

	token := base64.URLEncoding.EncodeToString(hash.Sum(nil))
	return token
}

// GetVerifiedIdentity retrieves a verified identity by public key
func (rh *RegistrationHandler) GetVerifiedIdentity(publicKey string) *VerifiedIdentity {
	rh.identitiesMu.RLock()
	defer rh.identitiesMu.RUnlock()

	return rh.verifiedIdentities[publicKey]
}
