package crypto

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
)

// ED25519PublicKeyFromHex parses an Ed25519 public key from hex string
func ED25519PublicKeyFromHex(hexStr string) (ed25519.PublicKey, error) {
	bytes, err := hex.DecodeString(hexStr)
	if err != nil {
		return nil, fmt.Errorf("invalid hex: %w", err)
	}
	
	if len(bytes) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("invalid ed25519 key length: expected %d, got %d", ed25519.PublicKeySize, len(bytes))
	}
	
	return ed25519.PublicKey(bytes), nil
}

// VerifySignature verifies an Ed25519 signature over a message
func VerifySignature(publicKeyHex string, message []byte, signature []byte) (bool, error) {
	pubKey, err := ED25519PublicKeyFromHex(publicKeyHex)
	if err != nil {
		return false, err
	}
	
	if len(signature) != ed25519.SignatureSize {
		return false, fmt.Errorf("invalid signature length: expected %d, got %d", ed25519.SignatureSize, len(signature))
	}
	
	return ed25519.Verify(pubKey, message, signature), nil
}

// HashPayload computes SHA256 hash of a payload
// Used for message integrity verification
func HashPayload(payload []byte) [32]byte {
	return sha256.Sum256(payload)
}
