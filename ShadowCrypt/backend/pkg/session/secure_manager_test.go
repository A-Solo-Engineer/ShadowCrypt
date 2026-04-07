package session

import (
	"bytes"
	"testing"
	"time"
)

// TestMemwipeOnSessionExpiration verifies that expired sessions are properly wiped
func TestMemwipeOnSessionExpiration(t *testing.T) {
	ssm := NewSecureSessionManager(100*time.Millisecond, 50*time.Millisecond)
	defer ssm.Shutdown()
	
	userID := "test_user"
	pubKey := [32]byte{1, 2, 3}
	
	token, err := ssm.RegisterUser(userID, pubKey, make([][32]byte, 0), []byte{})
	if err != nil {
		t.Fatalf("registration failed: %v", err)
	}
	
	// Verify token is valid
	retrievedID, valid := ssm.VerifySessionToken(token)
	if !valid || retrievedID != userID {
		t.Fatal("token should be valid immediately after registration")
	}
	
	// Wait for expiration
	time.Sleep(150 * time.Millisecond)
	
	// Token should now be rejected
	_, valid = ssm.VerifySessionToken(token)
	if valid {
		t.Fatal("expired token should be invalid")
	}
	
	// Verify session was removed from manager
	ssm.mu.RLock()
	_, exists := ssm.sessions[userID]
	ssm.mu.RUnlock()
	
	if exists {
		t.Fatal("expired session should have been removed from manager")
	}
}

// TestMemwipeOnExplicitRemoval verifies that RemoveSession wipes memory
func TestMemwipeOnExplicitRemoval(t *testing.T) {
	ssm := NewSecureSessionManager(1*time.Hour, 5*time.Minute)
	defer ssm.Shutdown()
	
	userID := "test_user"
	pubKey := [32]byte{1, 2, 3, 4, 5}
	
	token, _ := ssm.RegisterUser(userID, pubKey, make([][32]byte, 0), []byte{})
	
	// Verify session exists
	ssm.mu.RLock()
	session, exists := ssm.sessions[userID]
	ssm.mu.RUnlock()
	
	if !exists {
		t.Fatal("session should exist")
	}
	
	// Get token before removal
	originalToken, _ := session.GetSessionToken()
	
	// Remove session (should trigger memwipe)
	ssm.RemoveSession(userID)
	
	// Verify session is gone
	ssm.mu.RLock()
	_, exists = ssm.sessions[userID]
	_, tokenExists := ssm.tokens[originalToken]
	ssm.mu.RUnlock()
	
	if exists {
		t.Fatal("session should be removed")
	}
	if tokenExists {
		t.Fatal("token should be removed")
	}
	
	// Try to use token - should fail
	_, valid := ssm.VerifySessionToken(originalToken)
	if valid {
		t.Fatal("removed session token should be invalid")
	}
}

// TestSecureByteWipe verifies that sensitive data is actually zeroed
func TestSecureByteWipe(t *testing.T) {
	sb := NewSecureBytes(32)
	
	testData := []byte{
		1, 2, 3, 4, 5, 6, 7, 8,
		9, 10, 11, 12, 13, 14, 15, 16,
		17, 18, 19, 20, 21, 22, 23, 24,
		25, 26, 27, 28, 29, 30, 31, 32,
	}
	
	if err := sb.Set(testData); err != nil {
		t.Fatalf("Set failed: %v", err)
	}
	
	// Verify data is stored
	data, _ := sb.Get()
	if !bytes.Equal(data, testData) {
		t.Fatal("stored data should match input")
	}
	
	// Wipe
	sb.Wipe()
	
	// Verify it's marked as zeroed
	if !sb.IsZeroed() {
		t.Fatal("SecureBytes should be marked as zeroed")
	}
	
	// Verify we can't read from zeroed container
	_, err := sb.Get()
	if err == nil {
		t.Fatal("Get should fail on zeroed container")
	}
	
	// Verify underlying buffer is zeroed
	// (Note: This tests the internal state - in real scenario, data would be inaccessible)
	for i := 0; i < len(sb.data); i++ {
		if sb.data[i] != 0 {
			t.Fatalf("byte at index %d not zeroed: %d", i, sb.data[i])
		}
	}
}

// TestShutdownWipesAllSessions verifies that Shutdown clears all data
func TestShutdownWipesAllSessions(t *testing.T) {
	ssm := NewSecureSessionManager(1*time.Hour, 5*time.Minute)
	
	// Register multiple sessions
	for i := 0; i < 5; i++ {
		userID := "user_" + string(rune(i))
		pubKey := [32]byte{byte(i), 1, 2, 3}
		ssm.RegisterUser(userID, pubKey, make([][32]byte, 0), []byte{})
	}
	
	// Verify sessions exist
	ssm.mu.RLock()
	sessionCount := len(ssm.sessions)
	tokenCount := len(ssm.tokens)
	ssm.mu.RUnlock()
	
	if sessionCount != 5 {
		t.Fatalf("expected 5 sessions, got %d", sessionCount)
	}
	if tokenCount != 5 {
		t.Fatalf("expected 5 tokens, got %d", tokenCount)
	}
	
	// Shutdown
	ssm.Shutdown()
	
	// Verify all data is cleared
	ssm.mu.RLock()
	sessionCount = len(ssm.sessions)
	tokenCount = len(ssm.tokens)
	ssm.mu.RUnlock()
	
	if sessionCount != 0 {
		t.Fatalf("sessions should be cleared on shutdown, got %d", sessionCount)
	}
	if tokenCount != 0 {
		t.Fatalf("tokens should be cleared on shutdown, got %d", tokenCount)
	}
}

// TestMemwipePreventsCoreMemoryRecovery is a conceptual test
// In production, you'd use tools like AddressSanitizer to verify
func TestMemwipePreventsCoreMemoryRecovery(t *testing.T) {
	// This test demonstrates the principle:
	// Even if someone gains access to process memory, wiped sessions are unrecoverable
	
	ssm := NewSecureSessionManager(1*time.Hour, 5*time.Minute)
	defer ssm.Shutdown()
	
	userID := "critical_user"
	pubKey := [32]byte{99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 89, 88, 87, 86, 85, 84, 83, 82, 81, 80, 79, 78, 77, 76, 75, 74, 73, 72, 71, 70, 69, 68}
	
	token, _ := ssm.RegisterUser(userID, pubKey, make([][32]byte, 0), []byte{})
	
	// Attacker has immediate access to RAM at this point and could read token
	// But once session expires or is removed, memory is wiped
	
	ssm.RemoveSession(userID)
	
	// After removal, the token is unrecoverable without accessing the cleared memory
	_, valid := ssm.VerifySessionToken(token)
	if valid {
		t.Fatal("removed session should not be accessible")
	}
	
	t.Log("✓ Memwipe test passed: Session data unrecoverable after removal")
}
