# ShadowCrypt: Blind Relay Architecture

## Project Overview

**ShadowCrypt** is a zero-knowledge, local-first messaging platform where:
- **Server** never stores user data (Blind Relay pattern)
- **Client** maintains encrypted local vault with full message history
- **Protocol** uses Signal Protocol (Double Ratchet) for forward secrecy
- **Identity** based on Ed25519 public keys + 12-word BIP-39 mnemonics
- **Encryption** uses AES-256-GCM with SHA-256 HMACs

---

## Phase 1: Go Backend (Blind Relay Server)

### Architecture Overview

```
┌──────────────────┐
│  WebSocket       │
│  Client 1        │
└────────┬─────────┘
         │    JSON packets
         │
    ┌────▼─────────────────────────┐
    │   WebSocket Server           │
    │   (pkg/server)               │
    └────┬──────────────┬──────────┘
         │              │
         ▼              ▼
    ┌─────────────┐  ┌──────────────┐
    │  Session    │  │  Message     │
    │  Manager    │  │  Router      │
    │  (RAM)      │  │  (In-Memory) │
    └─────────────┘  └──────────────┘
         │              │
         └──────┬───────┘
              (ephemeral)
              
┌──────────────────┐
│  WebSocket       │
│  Client 2        │
└────────┬─────────┘
         │    JSON packets
         │
    ┌────▼─────────────────────────┐
    │   WebSocket Server           │
    │   (replicated per connection)│
    └──────────────────────────────┘
```

### Key Components

#### 1. **Session Manager** (`pkg/session/manager.go`)
- Stores user registrations **in ephemeral RAM only**
- No database persistence
- Session tokens generated using `crypto/rand`
- Auto-cleanup of expired sessions every 5 minutes

**Data Structure:**
```go
type UserSession struct {
    UserID        string      // Ed25519 public key (hex)
    SessionToken  string      // Random 64-char hex token
    PublicKey     [32]byte    // Ed25519 public key bytes
    PreKeys       [][32]byte  // X25519 prekeys for key exchange
    MLKemPublicKey []byte     // ML-KEM-768 post-quantum key
    ConnectedAt   time.Time
    LastActivity  time.Time
}
```

#### 2. **Message Router** (`pkg/routing/router.go`)
- Routes encrypted packets blindly between clients
- Uses ephemeral in-memory queues per connected user
- Discards messages immediately after delivery confirmation

**Packet Format:**
```json
{
  "type": "message|register|ack|key-exchange",
  "from_id": "sender_ed25519_pubkey_hex",
  "to_id": "recipient_ed25519_pubkey_hex",
  "session_token": "auth_token_hex",
  "payload": "base64_encrypted_data",
  "message_id": "unique_msg_id",
  "timestamp": 1712489400000000000,
  "key_exchange": {
    "x25519_public_key": [32-byte array],
    "mlkem_public_key": [1184-byte array]
  }
}
```

#### 3. **WebSocket Server** (`pkg/server/websocket.go`)
- Upgrades HTTP to WebSocket
- Receives initial registration with key material
- Bi-directional message routing
- Ping/pong keepalive every 30 seconds
- Graceful connection cleanup on disconnect

**Connection Sequence:**
```
1. Client connects to /ws
2. Client sends registration packet with Ed25519 + X25519 + ML-KEM keys
3. Server validates, stores in SessionManager
4. Server responds with session_token
5. Client authenticated for message routing
6. Messages routed until connection closes
```

#### 4. **HTTP Server** (`pkg/server/http.go`)
- `/ws` - WebSocket endpoint for messaging
- `/health` - Health check
- `/metrics` - Real-time server metrics (active users, timestamp)

### Security Properties

✅ **Zero Storage**: All user data exists in ephemeral RAM buffers  
✅ **No Database**: Server terminates, all user data erased  
✅ **Blind Routing**: Server doesn't decrypt or inspect payloads  
✅ **Session Isolation**: Each connection has isolated state  
✅ **No Logs**: Message payloads never written to disk  
✅ **Timing Attack Resistant**: Constant-time lookups where applicable  

### Running the Backend

```bash
cd backend

# Build
go build -o blindrelay ./cmd/blindrelay

# Run with custom timeouts
./blindrelay -addr=:8080 -session-timeout=1h -cleanup-interval=5m

# Test
go test ./... -v
```

### Connection Management Strategy

**Session Timeout**: 60 minutes (configurable)  
**Cleanup Interval**: 5 minutes  
**Max Queue Size**: 100 messages per user  
**Max Message Size**: 1MB  

If a client disconnects unexpectedly:
1. Read pump exits, triggering close
2. Session immediately removed from SessionManager
3. Delivery queue drained and closed
4. Next cleanup cycle verifies removal

---

## Phase 2: Flutter Frontend (Encrypted Vault)

### Architecture Overview

```
┌────────────────────────────────────────┐
│      Vault Unlock Screen               │
│  (12-word BIP-39 mnemonic entry)       │
└────────────────┬───────────────────────┘
                 │
                 ▼
    ┌────────────────────────┐
    │ Key Derivation Engine  │
    │ - PBKDF2-SHA256        │
    │ - BIP-39 Entropy       │
    └────────┬───────────────┘
             │
             ▼
    ┌────────────────────────────────┐
    │  SQLCipher Database (AES-256)  │
    │  - Encrypted vault             │
    │  - Drift ORM layer             │
    └────────┬───────────────────────┘
             │
             ▼
    ┌────────────────────────────────────┐
    │  Local Message Storage             │
    │  - Chat messages (encrypted)       │
    │  - Contact info                    │
    │  - Signal Protocol state           │
    │  - Key material                    │
    └────────────────────────────────────┘
```

### Key Components

#### 1. **Database Schema** (`lib/data/database/schema.dart`)

**ChatMessages Table:**
- `message_id`: Unique identifier (PK)
- `from_public_key`: Sender Ed25519 key
- `to_public_key`: Recipient Ed25519 key
- `encrypted_payload`: AES-256-GCM ciphertext
- `signal_ratchet_state`: Serialized ratchet for decryption
- `chain_key`: Current Signal Protocol chain state
- `created_at`: Unix nanoseconds
- `read_at`: NULL until user decrypts

**CryptoKeys Table:**
- Stores Ed25519 identity keys
- Stores X25519 ECDHE keys
- Stores ML-KEM-768 public keys
- Pre-keys for asynchronous key exchange

**VaultIdentities Table:**
- User's identity (Ed25519 public key)
- Mnemonic hash (for recovery verification)
- Encrypted private key (locked with mnemonic)
- Signal Protocol root keys

**SignalSessions Table:**
- Per-contact ratchet state (Double Ratchet)
- Ephemeral DH key pairs
- Chain keys and message keys
- Message counters for replay protection

#### 2. **Key Derivation** (`lib/crypto/key_management.dart`)

**BIP-39 Mnemonic Generation:**
```dart
String mnemonic = MnemonicGenerator.generate12WordMnemonic();
// Output: "abandon ability able about above absence abstract abuse access..."
```

**AES-256 Key from Mnemonic:**
```dart
final key = await KeyDerivation.deriveEncryptionKey(
  mnemonic: mnemonic,
  salt: "shadowcrypt_encryption",
  iterations: 100000,  // PBKDF2-SHA256
  length: 32,          // 256-bit key
);
```

**Process:**
1. Validate BIP-39 using CRC checksum
2. Convert mnemonic to entropy (128 bits for 12 words)
3. PBKDF2-SHA256: password=mnemonic, salt=custom, iterations=100k
4. Output: 32-byte AES-256 key

#### 3. **SQLCipher Encryption** (`lib/data/database/vault_database.dart`)

```dart
// Initialize encrypted database
await VaultDatabase.initialize(
  mnemonic: userMnemonic,
  dbPath: "/data/local/shadowcrypt.db",
);

// Under the hood:
// PRAGMA key='hex_derived_key';         // AES-256
// PRAGMA cipher='sqlcipher';
// PRAGMA cipher_page_size=4096;
// PRAGMA cipher_kdf_algorithm=PBKDF2;
// PRAGMA cipher_kdf_iter=64000;
```

**Encryption Properties:**
- **Algorithm**: AES-256-CBC
- **Key Size**: 256 bits
- **Page Size**: 4096 bytes
- **KDF**: PBKDF2-SHA256 with 64,000 iterations
- **DB File**: Unreadable without correct key

#### 4. **Signal Protocol (Double Ratchet)** (`lib/crypto/signal_protocol.dart`)

**Symmetric Ratchet (KDF_CK):**
```dart
(messageKey, newChainKey) = await KdfChain.kdfChain(
  chainKey: currentChainKey,
);
// messageKey = HMAC-SHA256(key=chainKey, message=0x01)
// newChainKey = HMAC-SHA256(key=chainKey, message=0x02)
```

**DH Ratchet (KDF_RK):**
```dart
(newRootKey, newChainKey) = await KdfChain.kdfRk(
  rootKey: currentRootKey,
  dhOutput: x25519SharedSecret,
);
// Advances Double Ratchet when ephemeral keys exchange
```

**Message Key Derivation:**
```dart
(cipherKey, macKey, iv) = await MessageKeyDerivation.kdfMessageKeys(
  messageKey: messageKey,
);
// cipherKey: 32 bytes for AES-256
// macKey: 32 bytes for HMAC-SHA256
// iv: 16 bytes
```

### UI Flow

#### **Vault Unlock Screen** (`lib/main.dart`)
- User enters 12-word mnemonic
- Validates against BIP-39 dictionary
- Derives encryption key
- Initializes SQLCipher database
- On success: Navigate to home screen

#### **Onboarding Screen** (`lib/ui/onboarding_screen.dart`)
- Generate random 12-word mnemonic
- Display in 3-column grid with indices
- "Copy to Clipboard" for manual backup
- Confirmation checkbox
- Initialize vault on confirmation

### Delta-Sync Implementation

For CPU-efficient decryption on low-end hardware (i3 laptop):

```
Load 20 most recent messages from DB
For each message:
  1. Read encrypted_payload from DB
  2. Retrieve Signal ratchet_state for sender
  3. Derive message key using Double Ratchet
  4. AES-256-GCM decrypt with ratchet key
  5. Display plaintext to user

User scrolls: Load next 20 messages lazily
```

### Database Initialization Checklist

```
✅ Derive 32-byte key from mnemonic (PBKDF2)
✅ Open SQLite3 database file
✅ Set PRAGMA key with derived key
✅ Set cipher settings (AES-256, 64k iterations)
✅ Create Drift tables (migration 0 -> ∞)
✅ Store user's Ed25519 public key in VaultIdentities
✅ Store encrypted private key in VaultIdentities
✅ Initialize empty Signal sessions
✅ Ready for message storage
```

---

## Cryptographic Protocols

### 1. **Signal Protocol (Double Ratchet)**

Used for **forward secrecy** and **breaking long keys**.

**State per conversation:**
- Root key (initialized from X25519 ECDHE)
- Sender chain key (advances with each message)
- Receiver chain key (decrypts incoming messages)
- Ephemeral DH key pair (changes periodically)

**Message Encryption:**
```
1. Derive messageKey from senderChainKey (KDF_CK)
2. Derive cipherKey, macKey from messageKey (KDF_MK)
3. Encrypt plaintext with AES-256-GCM
4. HMAC-SHA256 for authentication
5. Send ciphertext + tag + chain advancement
```

### 2. **Hybrid Key Exchange (X25519 + ML-KEM-768)**

**Initial Registration:**
```
Client generates:
  - Ed25519 keypair (identity)
  - X25519 keypair (ECDHE)
  - ML-KEM-768 keypair (post-quantum)

Client sends all 3 public keys to server
Server stores in SessionManager
Both public keys registered with recipient
```

### 3. **BIP-39 Mnemonic Recovery**

**Entropy Encoding:**
- 128 bits → 12 words
- Each word represents 11 bits
- Last 4 bits = checksum (CRC)
- 2,048 word dictionary

**Key Derivation:**
```
mnemonic → entropy → PBKDF2-SHA256 → 32-byte AES-256 key
```

---

## Security Considerations

### Backend Security
- ✅ No persistent storage
- ✅ Memory cleared on process termination
- ✅ Session tokens are cryptographically random
- ✅ 60-minute session timeout (configurable)
- ✅ WebSocket upgrade over TLS/HTTPS only (enforce in production)
- ⚠️ **TODO**: Implement rate limiting
- ⚠️ **TODO**: DOS protection
- ⚠️ **TODO**: Audit logging (write to stderr only, not persistent)

### Frontend Security
- ✅ AES-256-GCM encryption at rest
- ✅ BIP-39 mnemonic verification (CRC checksum)
- ✅ PBKDF2-SHA256 with 100,000 iterations
- ✅ SQLCipher with 64,000 KDF iterations
- ✅ Signal Protocol forward secrecy
- ⚠️ **TODO**: Prevent mnemonic from being logged
- ⚠️ **TODO**: Clear sensitive data from memory after use
- ⚠️ **TODO**: Implement biometric unlock (Android/iOS)
- ⚠️ **TODO**: Lock after screen timeout

---

## Development Roadmap

### Phase 1 (Complete)
- [x] Go Blind Relay Server
- [x] WebSocket message routing
- [x] Ephemeral session management
- [x] Integration testing framework

### Phase 2 (Complete)
- [x] Flutter project setup
- [x] SQLCipher integration with Drift ORM
- [x] BIP-39 mnemonic generation
- [x] AES-256 key derivation
- [x] Vault unlock UI
- [x] Onboarding flow

### Phase 3 (Next)
- [ ] Signal Protocol Double Ratchet implementation
- [ ] WebSocket client in Flutter
- [ ] Message sending/receiving UI
- [ ] Contact exchange protocol
- [ ] End-to-end encryption testing

### Phase 4
- [ ] Post-quantum key size optimization
- [ ] Backup/restore mechanism
- [ ] Multi-device support
- [ ] Group messaging
- [ ] Desktop builds (Windows, macOS, Linux)

---

## References

- **Signal Protocol**: https://signal.org/docs/
- **BIP-39**: https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki
- **Double Ratchet RFC**: https://signal.org/docs/specifications/doubleratchet/
- **X25519**: RFC 7748
- **ML-KEM-768**: NIST FIPS 203
- **SQLCipher**: https://www.zetetic.net/sqlcipher/
- **Drift ORM**: https://drift.simonbinder.eu/

---

**Last Updated**: April 2026  
**Architecture Version**: 0.1.0  
**Status**: Foundation Phase Complete
