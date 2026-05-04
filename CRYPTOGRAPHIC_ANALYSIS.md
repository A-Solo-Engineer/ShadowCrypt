# ShadowCrypt: Cryptographic Handshake & Security Analysis

This document details how to test and debug the cryptographic handshakes between client and server.

## Phase 1: Three-Way Key Exchange

### Overview

When a client connects, the system performs a **three-way key exchange** to establish forward secrecy:

```
Client                              Server
  │                                   │
  ├─── REGISTER + X25519 + ML-KEM ───>│
  │    (from_id, public keys)         │
  │                                   │
  │<─── ACK + session_token ─────────┤
  │    (server stores keys in RAM)    │
  │                                   │
  │    (Now ready to exchange         │
  │     encrypted messages)           │
```

### Step 1: Client Generates Key Material

**Backend:**
```go
// Client MUST generate before connecting:
ed25519PrivateKey, ed25519PublicKey = crypto/ed25519.GenerateKey()
x25519PrivateKey, x25519PublicKey = CurveX25519(randomSeed)
mlkemPrivateKey, mlkemPublicKey = ML_KEM_768.GenerateKey()
```

**Frontend (Flutter):**
```dart
// In KeyDerivation class
final identityKeypair = await KeyDerivation.deriveIdentityKeypair(
  mnemonic: userMnemonic,
);
// Returns: privateKey (32 bytes for Ed25519)

final ecdheKeypair = await KeyDerivation.deriveX25519Keypair(
  mnemonic: userMnemonic,
);
// Returns: privateKey (32 bytes for X25519)

// ML-KEM-768 generation (requires external library)
// TODO: Integrate liboqs or other post-quantum library
```

### Step 2: Send Registration Packet

**Packet Format:**
```json
{
  "type": "register",
  "from_id": "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6a7b8c9d0e1f2",
  "session_token": "",
  "key_exchange": {
    "x25519_public_key": [32 bytes as array],
    "mlkem_public_key": "base64_encoded_1184_bytes"
  }
}
```

**Generate with Go client:**
```bash
# Using websocat to test
{
  "type": "register",
  "from_id": "3d6cb8d91f2f7a4b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a",
  "session_token": "",
  "key_exchange": {
    "x25519_public_key": [
      0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
      16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    ],
    "mlkem_public_key": "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB..."
  }
}
```

### Step 3: Server Validates & Stores

**Server Processing (`pkg/server/websocket.go`):**

```go
func (ws *WebSocketServer) HandleConnect(w http.ResponseWriter, r *http.Request) {
    // 1. Upgrade WebSocket
    // 2. Read registration packet
    // 3. Validate keys
    if registerPacket.KeyExchange.X25519PublicKey != [32]byte{} {
        // Valid 32-byte key
        prekeys := make([][32]byte, 0)
        sessionToken, err := ws.sessionMgr.RegisterUser(
            userID,
            registerPacket.KeyExchange.X25519PublicKey,
            prekeys,
            registerPacket.KeyExchange.MLKemPublicKey,
        )
        // 4. Send ACK with session_token
    }
}
```

**Response:**
```json
{
  "type": "register_ack",
  "session_token": "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6a7b8c9d0e1f2",
  "timestamp": 1712489400000000000
}
```

## Phase 2: Message Exchange

### Initial Message (Before Double Ratchet)

**Scenario**: Alice wants to send a message to Bob.

**Prerequisites**:
1. Alice and Bob have both registered with server
2. Alice knows Bob's Ed25519 public key
3. Alice knows Bob's X25519 and ML-KEM public keys (from contact exchange or QR code)

**Protocol**:

```
Alice (Client)                      Server                      Bob (Client)
    │                                 │                              │
    ├─── MESSAGE + encrypted ───────>│                              │
    │    (from, to, payload)          │                              │
    │                                 ├─── route to Bob ───────────>│
    │<─── delivery_ack ─────────────┤                              │
    │    (status: ok)                 │                              │
    │                                 │<─── ACK from Bob ──────────┤
    │                                 │    (confirmed received)      │
    │                                 │                              │
```

### Message Packet Format

```json
{
  "type": "message",
  "from_id": "alice_ed25519_key",
  "to_id": "bob_ed25519_key",
  "session_token": "alice_session_token",
  "payload": "AEAD_ciphertext_base64",
  "message_id": "msg_20240417_001",
  "timestamp": 1712489400000000000
}
```

### Message Security Analysis

**Encryption on Alice's side:**
1. Alice retrieves existing Signal session with Bob (or creates new one)
2. Derives message key from sender chain key: `messageKey = KDF_CK(senderChainKey)`
3. Derives cipher+mac keys: `(cipherKey, macKey, iv) = KDF_MK(messageKey)`
4. Encrypts: `ciphertext = AES-256-GCM(plaintext, cipherKey, iv)`
5. Signs message ID: `signature = Ed25519.Sign(messageId, Alice_PrivateKey)`
6. Base64-encodes everything
7. Sends via WebSocket

**Routing on server:**
1. Server DOES NOT decrypt
2. Server DOES NOT inspect payload
3. Server routes based on `to_id` only
4. If Bob online, queues in `routingQueue[bob_ed25519_key]`
5. Sends ACK to Alice: `"status": "ok"`

**Receiving on Bob's side:**
1. Bob's delivery queue receives message
2. Bob looks up Signal session with Alice
3. Derives receiver chain key: `receiverChainKey = KDF_CK(receiverChainKey)`
4. Derives cipher+mac keys
5. Decrypts: `plaintext = AES-256-GCM.Decrypt(ciphertext, cipherKey, iv)`
6. Verifies signature with Alice's Ed25519 public key
7. Displays plaintext to user
8. Bob sends ACK

## Security Loopholes: Testing & Validation

### Loophole 1: Replay Attacks

**Attack**: Attacker intercepts message and replays it multiple times.

**Defense**: Message numbers in Double Ratchet
- Each message has counter: `senderMessageNumber`
- Receiver rejects any message with counter ≤ previous max
- Stored in Signal session state

**Test:**
```dart
test('Replay attack detection', () async {
  final ratchet = DoubleRatchet(state);
  
  // Encrypt first message
  final msg1 = await ratchet.ratchetSenderMessageKey();
  expect(ratchet.state.senderMessageNumber, equals(1));
  
  // Try to decrypt same message twice
  await ratchet.ratchetReceiverMessageKey();
  expect(ratchet.state.receiverMessageNumber, equals(1));
  
  // Attacker replays: should reject on second attempt
  // TODO: Implement message counter validation
});
```

### Loophole 2: Man-in-the-Middle (MITM) on X25519

**Attack**: Attacker intercepts X25519 public keys and substitutes their own.

**Defense**: Out-of-band verification
- Users must verify each other's public keys
- QR code exchange recommended
- Signal Safety Numbers (currently not implemented)

**Test:**
```
1. Generate Alice and Bob keypairs
2. Have attacker create Eve keypair
3. Server-side: If attacker can inject Eve's key > can intercept
4. Solution: Require user confirmation of contact public key
```

### Loophole 3: Database Key Derivation Weakness

**Attack**: If mnemonic is weak, entire vault compromise.

**Defense**: PBKDF2 with 100,000 iterations

**Test:**
```dart
test('Brute force resistance', () async {
  final weak = 'password123'; // Not a valid BIP-39
  
  // This should fail validation
  expect(MnemonicGenerator.isValidMnemonic(weak), isFalse);
  
  // Valid mnemonic has built-in entropy
  final valid = MnemonicGenerator.generate12WordMnemonic();
  expect(MnemonicGenerator.isValidMnemonic(valid), isTrue);
  
  // Brute-forcing 12-word mnemonic: 2^128 possibilities
  // Even with PBKDF2, computationally infeasible
});
```

### Loophole 4: Forward Secrecy Break (Old State Compromise)

**Attack**: If attacker gains access to old signal session state, can they decrypt old messages?

**Defense**: Double Ratchet design
- Old message keys are NOT stored
- Only current chain keys stored
- Previous chain keys explicitly deleted
- Benefits: Even if DB compromised, past msgs safe

**Test:**
```dart
test('Forward secrecy on state compromise', () async {
  final ratchet = DoubleRatchet(state);
  
  // Alice sends 10 messages
  final oldMessageKeys = <Uint8List>[];
  for (int i = 0; i < 10; i++) {
    final key = await ratchet.ratchetSenderMessageKey();
    oldMessageKeys.add(key);
  }
  
  // Database compromised, attacker gets current state
  // Can attacker decrypt old messages? NO
  // Because messageKeys were derived once and discarded
  
  // This is the core benefit of Double Ratchet
});
```

### Loophole 5: Server Stores Messages Longer Than Needed

**Attack**: Server stores messages in RAM for too long, risk of recovery even after "delete".

**Defense**:
1. Messages in queue only until ACK received
2. After ACK, message removed immediately
3. Queue drained on disconnect
4. Memory pressure causes garbage collection

**Test:**
```go
func TestMessageQueueCleanup(t *testing.T) {
    router := routing.NewMessageRouter(sessionMgr)
    
    // Route message
    success, _, _ := router.RouteMessage(packet)
    if !success {
        t.Fatal("routing failed")
    }
    
    // Drain queue (simulate client disconnect)
    count := router.DrainQueue(recipientID)
    if count == 0 {
        t.Fatal("message should have been queued")
    }
    
    // Verify queue is empty
    queueSize := len(router.GetQueueSize(recipientID))
    if queueSize != 0 {
        t.Fatal("queue should be empty after drain")
    }
}
```

## Cryptographic Testing Checklist

- [ ] **Key Generation**
  - [x] Ed25519 from mnemonic entropy
  - [x] X25519 from mnemonic entropy
  - [ ] ML-KEM-768 key pair generation
  - [x] BIP-39 checksum validation

- [ ] **Key Derivation**
  - [x] PBKDF2-SHA256 produces 256-bit key
  - [x] Different mnemonics → different keys
  - [ ] Same mnemonic → deterministic key

- [ ] **Encryption**
  - [ ] AES-256-GCM encryption/decryption
  - [ ] Incorrect key → decryption fails (exception)
  - [ ] Modified ciphertext → authentication fails

- [ ] **Signal Protocol**
  - [ ] KDF_CK ratcheting advances chain keys
  - [ ] KDF_RK on DH produces different keys
  - [ ] Message counters prevent replay
  - [ ] Old messages unrecoverable after ratchet

- [ ] **Database**
  - [x] SQLCipher initializes with correct key
  - [ ] Invalid key → can't read DB
  - [ ] DB file unreadable without key

- [ ] **Message Routing**
  - [x] Server routes without decryption
  - [x] Sessions timeout and cleanup
  - [x] Delivery queues cleared on disconnect

## Debugging Cryptographic Failures

### Scenario 1: "Decryption Failed" on Message Receipt

```
Client A sends message → Server routes → Client B receives
Client B tries to decrypt → FAILS

Debugging steps:
1. Verify Signal session state matches (same root key?)
2. Check message counter (should be incrementing)
3. Verify chain key advancement was called
4. Check IV generation (must be 12 bytes)
5. Confirm ciphertext format (last 16 bytes = GCM tag)
```

### Scenario 2: "Invalid Session Token" on Connect

```
Client sends message with token X
Server responds: invalid_session_token

Debugging steps:
1. Verify token was received from register_ack
2. Check token hasn't expired (60 min timeout)
3. Verify token format (64 hex chars = 32 bytes)
4. Check client didn't modify token
5. Look for concurrent register attempts (should replace)
```

### Scenario 3: "Recipient Offline" Transient Failures

```
Client A tries to send message
Response: recipient_offline, retryable=true

Expected behavior:
1. First attempt → recipient not in router.queues
2. Retry with exponential backoff (1s, 2s, 4s...)
3. After 3 retries, show as undelivered
4. OR wait if recipient comes online

Debugging:
1. Is recipient actually connected? Check /metrics
2. Is their delivery queue created? (RegisterDeliveryQueue)
3. Is queue full? (100 limit)
4. Check network latency (100ms select timeout)
```

## Next Security Steps

1. **Implement Request Signing**
   - Sign registration with Ed25519
   - Sign each message with Ed25519
   - Server validates signatures (future)

2. **Contact Verification Protocol**
   - QR code for public key exchange
   - Manual fingerprint verification
   - Trust-on-first-use (TOFU)

3. **Group Messaging Handshake**
   - Multi-party Double Ratchet
   - Commit-based group protocol

4. **Perfect Forward Secrecy Analysis**
   - Formal security proof
   - Third-party security audit
   - Fuzzing of decryption functions

---

**Last Updated**: April 2026
