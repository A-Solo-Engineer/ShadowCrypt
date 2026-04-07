package routing

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/shadowcrypt/blindrelay/pkg/session"
)

func TestMessagePacketValidation(t *testing.T) {
	tests := []struct {
		name      string
		packet    *MessagePacket
		shouldErr bool
	}{
		{
			name: "valid registration packet",
			packet: &MessagePacket{
				Type:   "register",
				FromID: "abc123def456",
				KeyExchange: &KeyExchangePayload{
					MLKemPublicKey: []byte("mlkem_key"),
				},
			},
			shouldErr: false,
		},
		{
			name: "missing type",
			packet: &MessagePacket{
				FromID: "abc123",
			},
			shouldErr: true,
		},
		{
			name: "valid message packet",
			packet: &MessagePacket{
				Type:    "message",
				FromID:  "sender123",
				ToID:    "recipient456",
				Payload: "encrypted_data",
			},
			shouldErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ValidatePacket(tt.packet)
			if (err != nil) != tt.shouldErr {
				t.Fatalf("expected error: %v, got: %v", tt.shouldErr, err)
			}
		})
	}
}

func TestMessageRouting(t *testing.T) {
	sessionMgr := session.NewSessionManager(60*time.Minute, 5*time.Minute)
	router := NewMessageRouter(sessionMgr)

	// Register sender
	senderID := "sender_ed25519_pubkey"
	senderKey := [32]byte{1, 2, 3}
	senderToken, err := sessionMgr.RegisterUser(senderID, senderKey, make([][32]byte, 0), []byte{})
	if err != nil {
		t.Fatalf("failed to register sender: %v", err)
	}

	// Register recipient
	recipientID := "recipient_ed25519_pubkey"
	recipientKey := [32]byte{4, 5, 6}
	_, err = sessionMgr.RegisterUser(recipientID, recipientKey, make([][32]byte, 0), []byte{})
	if err != nil {
		t.Fatalf("failed to register recipient: %v", err)
	}

	// Create delivery queue for recipient
	queue := router.RegisterDeliveryQueue(recipientID)

	// Send message
	packet := &MessagePacket{
		Type:         "message",
		FromID:       senderID,
		ToID:         recipientID,
		SessionToken: senderToken,
		Payload:      "test_encrypted_data",
		MessageID:    "msg_123",
		Timestamp:    time.Now().UnixNano(),
	}

	success, _, _ := router.RouteMessage(packet)
	if !success {
		t.Fatal("routing should have succeeded")
	}

	// Verify message in queue
	select {
	case received := <-queue.Messages:
		if received.MessageID != "msg_123" {
			t.Fatalf("expected msg_123, got %s", received.MessageID)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("message not received in queue")
	}
}

func TestPacketParsing(t *testing.T) {
	jsonData := `{
		"type": "message",
		"from_id": "sender_key",
		"to_id": "recipient_key",
		"payload": "encrypted_data",
		"message_id": "msg_001"
	}`

	packet, err := ParsePacket([]byte(jsonData))
	if err != nil {
		t.Fatalf("parsing failed: %v", err)
	}

	if packet.Type != "message" {
		t.Fatalf("expected type 'message', got %s", packet.Type)
	}
	if packet.FromID != "sender_key" {
		t.Fatalf("expected from_id sender_key, got %s", packet.FromID)
	}
}
