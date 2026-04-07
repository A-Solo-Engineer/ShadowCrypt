import 'package:drift/drift.dart';

// ============================================================================
// DATABASE TABLES
// ============================================================================

/// Stores encrypted chat messages locally
@DataClassName("ChatMessage")
class ChatMessages extends Table {
  IntColumn get id => integer().autoIncrement()();
  
  TextColumn get messageId => text()();  // Unique message identifier
  TextColumn get fromPublicKey => text()();  // Sender's Ed25519 public key
  TextColumn get toPublicKey => text()();    // Recipient's Ed25519 public key
  TextColumn get encryptedPayload => text()(); // AES-256 encrypted message (base64)
  TextColumn get signatureHex => text()();   // Ed25519 signature
  
  IntColumn get createdAt => bigInt()();     // Unix nanoseconds
  IntColumn get deliveredAt => bigInt().nullable()();
  IntColumn get readAt => bigInt().nullable()();
  
  // Signal Protocol state
  TextColumn get ratchetState => text().nullable()(); // Serialized ratchet state
  TextColumn get chainKey => text().nullable()();     // Current chain key (hex)
  IntColumn get messageNumber => integer().withDefault(const Constant(0))();
  
  @override
  Set<Column> get primaryKey => {id, messageId};
  
  @override
  List<Set<Column>> get uniqueKeys => [
    {messageId, fromPublicKey, toPublicKey},
  ];
}

/// Stores Ed25519 and hybrid key material
@DataClassName("CryptoKey")
class CryptoKeys extends Table {
  IntColumn get id => integer().autoIncrement()();
  
  TextColumn get keyType => text()(); // "identity", "ecdhe", "mlkem"
  TextColumn get publicKeyHex => text()();
  TextColumn get privateKeyHex => text().nullable()(); // NULL for public keys only
  
  IntColumn get createdAt => bigInt()();
  IntColumn get expiresAt => bigInt().nullable()();
  
  TextColumn get metadata => text().nullable()(); // JSON metadata (e.g., prekey index)
  
  @override
  Set<Column> get primaryKey => {id};
  
  @override
  List<Set<Column>> get uniqueKeys => [
    {publicKeyHex},
  ];
}

/// Stores recovery/identity information
@DataClassName("VaultIdentity")
class VaultIdentities extends Table {
  IntColumn get id => integer().autoIncrement()();
  
  TextColumn get identityName => text().withDefault(const Constant('Default'))();
  TextColumn get ed25519PublicKeyHex => text()(); // User's identity
  TextColumn get mnemonicHash => text()();        // SHA256(mnemonic) for verification
  
  // Encrypted private key (encrypted with mnemonic-derived key)
  TextColumn get encryptedPrivateKeyHex => text()();
  
  // Signal Protocol state and ratchet roots
  TextColumn get signalRootKeyHex => text().nullable()();
  TextColumn get signalChainKeyHex => text().nullable()();
  
  IntColumn get createdAt => bigInt()();
  IntColumn get lastModifiedAt => bigInt()();
  
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  
  @override
  Set<Column> get primaryKey => {id};
  
  @override
  List<Set<Column>> get uniqueKeys => [
    {ed25519PublicKeyHex},
  ];
}

/// Contact list for recipient discovery
@DataClassName("Contact")
class Contacts extends Table {
  IntColumn get id => integer().autoIncrement()();
  
  TextColumn get displayName => text()();
  TextColumn get ed25519PublicKeyHex => text().unique()();
  
  // Hybrid key material for this contact
  TextColumn get x25519PublicKeyHex => text().nullable()();
  TextColumn get mlkemPublicKeyHex => text().nullable()();
  
  IntColumn get addedAt => bigInt()();
  IntColumn get lastSeenAt => bigInt().nullable()();
  
  TextColumn get notes => text().nullable()();
  
  @override
  Set<Column> get primaryKey => {id};
  
  @override
  List<Set<Column>> get uniqueKeys => [
    {ed25519PublicKeyHex},
  ];
}

/// Signal Protocol state per conversation
@DataClassName("SignalSession")
class SignalSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  
  TextColumn get remotePublicKeyHex => text()();
  
  // Ratchet state
  TextColumn get rootKeyHex => text()();
  TextColumn get senderChainKeyHex => text().nullable()();
  TextColumn get receiverChainKeyHex => text().nullable()();
  TextColumn get senderMessageKeyHex => text().nullable()();
  IntColumn get senderMessageNumber => integer().withDefault(const Constant(0))();
  IntColumn get receiverMessageNumber => integer().withDefault(const Constant(0))();
  
  // Double Ratchet ECDH pair
  TextColumn get ourEphemeralPrivateKeyHex => text()();
  TextColumn get ourEphemeralPublicKeyHex => text()();
  TextColumn get theirEphemeralPublicKeyHex => text().nullable()();
  
  IntColumn get createdAt => bigInt()();
  IntColumn get lastUpdatedAt => bigInt()();
  
  @override
  Set<Column> get primaryKey => {id};
  
  @override
  List<Set<Column>> get uniqueKeys => [
    {remotePublicKeyHex},
  ];
}
