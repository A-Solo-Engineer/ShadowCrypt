package session

import (
	"testing"
	"time"
)

func TestSessionRegistration(t *testing.T) {
	sm := NewSessionManager(5*time.Minute, 1*time.Minute)

	userID := "test_user_ed25519_key"
	pubKey := [32]byte{1, 2, 3, 4, 5}

	token, err := sm.RegisterUser(userID, pubKey, make([][32]byte, 0), []byte{})
	if err != nil {
		t.Fatalf("registration failed: %v", err)
	}

	if token == "" {
		t.Fatal("expected non-empty session token")
	}

	// Verify session exists
	session, found := sm.GetSession(userID)
	if !found {
		t.Fatal("session not found after registration")
	}

	if session.UserID != userID {
		t.Fatalf("expected userID %s, got %s", userID, session.UserID)
	}
}

func TestSessionExpiration(t *testing.T) {
	sm := NewSessionManager(100*time.Millisecond, 50*time.Millisecond) // Very short timeout for testing

	userID := "test_user"
	pubKey := [32]byte{1, 2, 3}

	_, err := sm.RegisterUser(userID, pubKey, make([][32]byte, 0), []byte{})
	if err != nil {
		t.Fatalf("registration failed: %v", err)
	}

	// Verify session exists
	_, found := sm.GetSession(userID)
	if !found {
		t.Fatal("session should exist")
	}

	// Wait for expiration
	time.Sleep(150 * time.Millisecond)

	// Verify session is expired
	_, found = sm.GetSession(userID)
	if found {
		t.Fatal("session should have expired")
	}
}

func TestTokenVerification(t *testing.T) {
	sm := NewSessionManager(5*time.Minute, 1*time.Minute)

	userID := "user_123"
	pubKey := [32]byte{1, 2, 3}

	token, err := sm.RegisterUser(userID, pubKey, make([][32]byte, 0), []byte{})
	if err != nil {
		t.Fatalf("registration failed: %v", err)
	}

	// Verify token
	retrievedID, valid := sm.VerifySessionToken(token)
	if !valid {
		t.Fatal("token validation failed")
	}

	if retrievedID != userID {
		t.Fatalf("expected userID %s, got %s", userID, retrievedID)
	}

	// Verify invalid token
	_, valid = sm.VerifySessionToken("invalid_token")
	if valid {
		t.Fatal("invalid token should not validate")
	}
}
