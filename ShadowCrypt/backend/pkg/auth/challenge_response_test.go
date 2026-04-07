package auth

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"testing"
	"time"

	"golang.org/x/crypto/ed25519"
)

// ============================================================================
// TEST SETUP
// ============================================================================

func generateTestKeys() (ed25519.PublicKey, ed25519.PrivateKey, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	return pub, priv, err
}

// ============================================================================
// CHALLENGE ISSUANCE TESTS
// ============================================================================

func TestIssueChallenge_Success(t *testing.T) {
	store := NewChallengeStore(5 * time.Minute)
	defer store.mu.Lock()
	defer store.mu.Unlock()

	pub, _, err := generateTestKeys()
	if err != nil {
		t.Fatalf("Failed to generate keys: %v", err)
	}

	challenge, err := store.IssueChallenge(pub)
	if err != nil {
		t.Errorf("IssueChallenge failed: %v", err)
	}

	if len(challenge.Nonce) != 32 {
		t.Errorf("Expected 32-byte nonce, got %d", len(challenge.Nonce))
	}

	if challenge.Status != "pending" {
		t.Errorf("Expected status 'pending', got '%s'", challenge.Status)
	}

	if challenge.ExpiresAt <= challenge.IssuedAt {
		t.Errorf("Expiration should be after issuance")
	}
}

func TestIssueChallenge_InvalidPublicKey(t *testing.T) {
	store := NewChallengeStore(5 * time.Minute)
	defer store.mu.Lock()
	defer store.mu.Unlock()

	invalidKey := []byte("short key")

	_, err := store.IssueChallenge(invalidKey)
	if err == nil {
		t.Error("Expected error for invalid public key")
	}
}

func TestIssueChallenge_UniqueNonces(t *testing.T) {
	store := NewChallengeStore(5 * time.Minute)
	defer store.mu.Lock()
	defer store.mu.Unlock()

	pub, _, _ := generateTestKeys()

	ch1, _ := store.IssueChallenge(pub)
	ch2, _ := store.IssueChallenge(pub)

	// Nonces should be different (cryptographically random)
	same := true
	for i := 0; i < 32; i++ {
		if ch1.Nonce[i] != ch2.Nonce[i] {
			same = false
			break
		}
	}

	if same {
		t.Error("Generated nonces should be different")
	}
}

// ============================================================================
// SIGNATURE VERIFICATION TESTS
// ============================================================================

func TestVerifyChallenge_ValidSignature(t *testing.T) {
	store := NewChallengeStore(5 * time.Minute)

	pub, priv, _ := generateTestKeys()

	challenge, _ := store.IssueChallenge(pub)

	// Client signs the nonce with their private key
	signature := ed25519.Sign(priv, challenge.Nonce)

	response := ChallengeResponse{
		ChallengeID: challenge.ID,
		Signature:   signature,
		PublicKey:   pub,
		Timestamp:   time.Now().UnixNano(),
	}

	verified, err := store.VerifyChallenge(response, "192.168.1.1", "TestAgent/1.0")
	if err != nil {
		t.Errorf("VerifyChallenge failed: %v", err)
	}

	if verified == nil {
		t.Error("Expected verified identity, got nil")
	}

	if verified.PublicKey != nil && base64.URLEncoding.EncodeToString(verified.PublicKey) != 
	   base64.URLEncoding.EncodeToString(pub) {
		t.Error("Public key mismatch in verified identity")
	}
}

func TestVerifyChallenge_InvalidSignature(t *testing.T) {
	store := NewChallengeStore(5 * time.Minute)

	pub1, _, _ := generateTestKeys()
	pub2, priv2, _ := generateTestKeys()

	challenge, _ := store.IssueChallenge(pub1)

	// Attacker signs with their own private key (not the one that matches pub1)
	signature := ed25519.Sign(priv2, challenge.Nonce)

	response := ChallengeResponse{
		ChallengeID: challenge.ID,
		Signature:   signature,
		PublicKey:   pub2, // Different key than requested
		Timestamp:   time.Now().UnixNano(),
	}

	verified, err := store.VerifyChallenge(response, "192.168.1.1", "TestAgent/1.0")
	if err == nil {
		t.Error("Expected error for invalid signature")
	}

	if verified != nil {
		t.Error("Expected nil verified identity for failed verification")
	}

	// Check that challenge was marked rejected
	ch, _ := store.GetChallenge(challenge.ID)
	if ch.Status != "rejected" {
		t.Errorf("Expected challenge status 'rejected', got '%s'", ch.Status)
	}
}

func TestVerifyChallenge_PublicKeyMismatch(t *testing.T) {
	store := NewChallengeStore(5 * time.Minute)

	pub1, _, _ := generateTestKeys()
	pub2, priv2, _ := generateTestKeys()

	challenge, _ := store.IssueChallenge(pub1)

	// Sign with priv2 but claim to be pub2 in response
	signature := ed25519.Sign(priv2, challenge.Nonce)

	response := ChallengeResponse{
		ChallengeID: challenge.ID,
		Signature:   signature,
		PublicKey:   pub2,
		Timestamp:   time.Now().UnixNano(),
	}

	verified, err := store.VerifyChallenge(response, "192.168.1.1", "TestAgent/1.0")
	if err == nil {
		t.Error("Expected error for public key mismatch")
	}

	if verified != nil {
		t.Error("Expected nil verified identity")
	}
}

// ============================================================================
// EXPIRATION TESTS
// ============================================================================

func TestVerifyChallenge_ExpiredChallenge(t *testing.T) {
	store := NewChallengeStore(1 * time.Millisecond) // Very short TTL

	pub, priv, _ := generateTestKeys()
	challenge, _ := store.IssueChallenge(pub)

	time.Sleep(10 * time.Millisecond) // Wait for expiration

	signature := ed25519.Sign(priv, challenge.Nonce)

	response := ChallengeResponse{
		ChallengeID: challenge.ID,
		Signature:   signature,
		PublicKey:   pub,
		Timestamp:   time.Now().UnixNano(),
	}

	verified, err := store.VerifyChallenge(response, "192.168.1.1", "TestAgent/1.0")
	if err == nil {
		t.Error("Expected error for expired challenge")
	}

	if verified != nil {
		t.Error("Expected nil verified identity for expired challenge")
	}
}

func TestCleanupExpiredChallenges(t *testing.T) {
	store := NewChallengeStore(10 * time.Millisecond)

	pub, _, _ := generateTestKeys()

	// Issue 5 challenges
	for i := 0; i < 5; i++ {
		store.IssueChallenge(pub)
	}

	store.mu.RLock()
	initialCount := len(store.challenges)
	store.mu.RUnlock()

	if initialCount != 5 {
		t.Errorf("Expected 5 challenges, got %d", initialCount)
	}

	// Wait for cleanup
	time.Sleep(50 * time.Millisecond)

	store.mu.RLock()
	finalCount := len(store.challenges)
	store.mu.RUnlock()

	if finalCount >= initialCount {
		t.Errorf("Expected cleanup to remove expired challenges, but %d remain", finalCount)
	}
}

// ============================================================================
// REPLAY PROTECTION TESTS
// ============================================================================

func TestReplayProtection_ChallengeReuse(t *testing.T) {
	store := NewChallengeStore(5 * time.Minute)

	pub, priv, _ := generateTestKeys()
	challenge, _ := store.IssueChallenge(pub)

	signature := ed25519.Sign(priv, challenge.Nonce)

	response := ChallengeResponse{
		ChallengeID: challenge.ID,
		Signature:   signature,
		PublicKey:   pub,
		Timestamp:   time.Now().UnixNano(),
	}

	// First verification should succeed
	verified1, err1 := store.VerifyChallenge(response, "192.168.1.1", "TestAgent/1.0")
	if err1 != nil {
		t.Errorf("First verification failed: %v", err1)
	}

	if verified1 == nil {
		t.Error("Expected verified identity")
	}

	// Attempt to reuse the same challenge
	verified2, err2 := store.VerifyChallenge(response, "192.168.1.1", "TestAgent/1.0")
	if err2 == nil {
		t.Error("Expected error for challenge reuse")
	}

	if verified2 != nil {
		t.Error("Expected nil verified identity for reused challenge")
	}
}

// ============================================================================
// RATE LIMITING TESTS
// ============================================================================

func TestRegistrationAttemptTracker_RateLimit(t *testing.T) {
	tracker := NewRegistrationAttemptTracker(5, 1*time.Minute)

	publicKey := "test_key_alice"
	ipAddress := "192.168.1.1"

	// Allow 5 attempts
	for i := 0; i < 5; i++ {
		err := tracker.RecordAttempt(publicKey, false, ipAddress)
		if err != nil {
			t.Errorf("Attempt %d failed: %v", i+1, err)
		}
	}

	// 6th attempt should fail
	err := tracker.RecordAttempt(publicKey, false, ipAddress)
	if err == nil {
		t.Error("Expected rate limit error on 6th attempt")
	}
}

func TestRegistrationAttemptTracker_WindowExpiry(t *testing.T) {
	tracker := NewRegistrationAttemptTracker(2, 10*time.Millisecond)

	publicKey := "test_key_alice"
	ipAddress := "192.168.1.1"

	// Record 2 attempts
	tracker.RecordAttempt(publicKey, false, ipAddress)
	tracker.RecordAttempt(publicKey, false, ipAddress)

	// Should be at limit
	if tracker.IsAllowed(publicKey) {
		t.Error("Expected rate limit to be in effect")
	}

	// Wait for window to expire
	time.Sleep(20 * time.Millisecond)

	// Should be allowed again
	if !tracker.IsAllowed(publicKey) {
		t.Error("Expected rate limit window to expire")
	}
}

// ============================================================================
// FULL REGISTRATION FLOW TEST
// ============================================================================

func TestRegistrationFlow_CompleteFlow(t *testing.T) {
	handler := NewRegistrationHandler()

	pub, priv, _ := generateTestKeys()
	ipAddress := "203.0.113.1"
	userAgent := "ShadowCrypt-Flutter/1.0"

	// Step 1: Request challenge
	challenge, err := handler.Step1_RequestChallenge(pub, ipAddress)
	if err != nil {
		t.Fatalf("Step 1 failed: %v", err)
	}

	if challenge == nil {
		t.Fatal("Expected challenge, got nil")
	}

	fmt.Println("✅ Step 1: Challenge issued")

	// Step 2: Sign the challenge
	signature := ed25519.Sign(priv, challenge.Nonce)

	response := ChallengeResponse{
		ChallengeID: challenge.ID,
		Signature:   signature,
		PublicKey:   pub,
		Timestamp:   time.Now().UnixNano(),
	}

	// Step 3: Submit response
	sessionToken, err := handler.Step2_SubmitChallengeResponse(response, ipAddress, userAgent)
	if err != nil {
		t.Fatalf("Step 2 failed: %v", err)
	}

	if sessionToken == "" {
		t.Error("Expected session token, got empty string")
	}

	fmt.Println("✅ Step 2: Challenge verified, session created")

	// Verify identity was stored
	keyStr := base64.URLEncoding.EncodeToString(pub)
	verified := handler.GetVerifiedIdentity(keyStr)
	if verified == nil {
		t.Error("Expected verified identity to be stored")
	}

	fmt.Printf("✅ Step 3: Identity verified and stored\n")
}

func TestRegistrationFlow_AttackerImpersonation(t *testing.T) {
	handler := NewRegistrationHandler()

	aliceKey, _, _ := generateTestKeys()
	bobKey, bobPriv, _ := generateTestKeys()
	
	ipAddress := "203.0.113.1"

	// Bob requests challenge pretending to be Alice
	challenge, _ := handler.Step1_RequestChallenge(aliceKey, ipAddress)

	// Bob tries to sign with his own key (and submit Bob's key instead)
	signature := ed25519.Sign(bobPriv, challenge.Nonce)

	response := ChallengeResponse{
		ChallengeID: challenge.ID,
		Signature:   signature,
		PublicKey:   bobKey, // Wrong key!
		Timestamp:   time.Now().UnixNano(),
	}

	sessionToken, err := handler.Step2_SubmitChallengeResponse(response, ipAddress, "TestAgent/1.0")
	if err == nil {
		t.Error("Expected verification to fail for impersonation attempt")
	}

	if sessionToken != "" {
		t.Error("Expected empty session token for failed verification")
	}

	fmt.Println("✅ Impersonation attempt blocked")
}

func TestRegistrationFlow_BruteForceProtection(t *testing.T) {
	handler := NewRegistrationHandler()

	pub, _, _ := generateTestKeys()
	ipAddress := "203.0.113.1"

	// Attempt 11 registrations (limit is 10 per 15 min)
	for i := 0; i < 11; i++ {
		_, err := handler.Step1_RequestChallenge(pub, ipAddress)

		if i < 10 {
			if err != nil {
				t.Errorf("Attempt %d should succeed: %v", i+1, err)
			}
		} else {
			if err == nil {
				t.Errorf("Attempt %d should be rate-limited", i+1)
			}
		}
	}

	fmt.Println("✅ Brute force protection active: 10 attempt limit enforced")
}
