import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';
import 'schema.dart';

part 'vault_database.g.dart';

/// Main encrypted database using SQLCipher (AES-256)
@DriftDatabase(
  tables: [
    ChatMessages,
    CryptoKeys,
    VaultIdentities,
    Contacts,
    SignalSessions,
  ],
)
class VaultDatabase extends _$VaultDatabase {
  // Private constructor
  VaultDatabase._({
    required QueryExecutor executor,
  }) : super.connect(executor);

  static VaultDatabase? _instance;

  // Singleton factory with lazy initialization
  static VaultDatabase? get instance => _instance;

  /// Initializes database with AES-256 encryption using SQLCipher
  /// Key is derived from BIP-39 mnemonic using PBKDF2
  static Future<void> initialize({
    required String mnemonic,
    required String dbPath,
  }) async {
    if (_instance != null) {
      return; // Already initialized
    }

    // Derive encryption key from mnemonic
    final encryptionKey = deriveEncryptionKeyFromMnemonic(mnemonic);

    // Setup SQLCipher with encrypted database
    final database = open(dbPath);

    // Enable SQLCipher with AES-256
    database.execute("PRAGMA cipher='sqlcipher';");
    database.execute("PRAGMA cipher_page_size=4096;");
    database.execute("PRAGMA cipher_kdf_algorithm=PBKDF2;");
    database.execute("PRAGMA cipher_kdf_iter=64000;");
    
    // Set encryption key
    database.execute("PRAGMA key='$encryptionKey';");

    // Verify encryption is working
    try {
      database.execute("SELECT COUNT(*) FROM sqlite_master;");
    } catch (e) {
      throw Exception("Database encryption verification failed: $e");
    }

    _instance = VaultDatabase._(
      executor: DatabaseConnection(database),
    );
  }

  /// Derives a 32-byte encryption key from a BIP-39 mnemonic
  /// Uses PBKDF2-SHA256 with 100,000 iterations
  static String deriveEncryptionKeyFromMnemonic(String mnemonic) {
    // In production, use actual PBKDF2 implementation
    // This is a placeholder - implement actual key derivation:
    // 1. Use mnemonic as password
    // 2. Salt = SHA256("shadowcrypt" || ed25519_pubkey)
    // 3. PBKDF2-SHA256(mnemonic, salt, 100000 iterations)
    // 4. Return hex string of first 32 bytes
    
    // For now, this is a basic implementation that needs cryptographic hardening
    return _pbkdf2SHA256(mnemonic, "shadowcrypt_encryption", iterations: 100000);
  }

  /// PBKDF2-SHA256 key derivation (placeholder - requires cryptography package)
  static String _pbkdf2SHA256(String password, String salt, {required int iterations}) {
    // This should use a proper PBKDF2 implementation from cryptography package
    // Placeholder implementation - DO NOT USE IN PRODUCTION
    throw UnimplementedError("Use cryptography package for PBKDF2-SHA256");
  }

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      // Create all tables on first run
      await m.createAll();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      // Handle future schema migrations
    },
  );

  /// Query unread messages for delta-sync (limit to 20)
  Future<List<ChatMessage>> getUnreadMessages({int limit = 20}) async {
    return select(chatMessages)
        .where((msg) => msg.readAt.isNull())
        .limit(limit)
        .get();
  }

  /// Get recent messages for a conversation partner
  Future<List<ChatMessage>> getConversationHistory({
    required String contactPublicKey,
    int limit = 20,
    int offset = 0,
  }) async {
    return (select(chatMessages)
            .where((msg) =>
                (msg.fromPublicKey.equals(contactPublicKey) |
                    msg.toPublicKey.equals(contactPublicKey)))
            .orderBy([(m) => OrderingTerm(expression: m.createdAt, mode: OrderingMode.desc)]))
        .limit(limit, offset: offset)
        .get();
  }

  /// Mark messages as read
  Future<void> markMessagesAsRead(List<String> messageIds) async {
    final batch = this.batch((batch) {
      batch.update(
        chatMessages,
        ChatMessagesCompanion(readAt: Value(DateTime.now().microsecondsSinceEpoch * 1000)),
        where: (m) => m.messageId.isIn(messageIds),
      );
    });
    await batch.commit();
  }

  /// Store encrypted message
  Future<void> insertMessage(ChatMessagesCompanion message) async {
    await into(chatMessages).insert(message);
  }

  /// Get the active identity
  Future<VaultIdentity?> getActiveIdentity() async {
    return (select(vaultIdentities)
            .where((identity) => identity.isActive.equals(true)))
        .getSingleOrNull();
  }

  /// Create new identity with encrypted private key
  Future<int> createIdentity({
    required String displayName,
    required String ed25519PublicKeyHex,
    required String mnemonicHash,
    required String encryptedPrivateKeyHex,
  }) async {
    return into(vaultIdentities).insert(
      VaultIdentitiesCompanion(
        identityName: Value(displayName),
        ed25519PublicKeyHex: Value(ed25519PublicKeyHex),
        mnemonicHash: Value(mnemonicHash),
        encryptedPrivateKeyHex: Value(encryptedPrivateKeyHex),
        createdAt: Value(DateTime.now().microsecondsSinceEpoch * 1000),
        lastModifiedAt: Value(DateTime.now().microsecondsSinceEpoch * 1000),
      ),
    );
  }

  /// Store Signal Protocol session state
  Future<void> updateSignalSession(SignalSessionsCompanion session) async {
    await into(signalSessions).insertOnConflictUpdate(session);
  }

  /// Retrieve Signal Protocol state for a contact
  Future<SignalSession?> getSignalSession(String remotePublicKeyHex) async {
    return (select(signalSessions)
            .where((s) => s.remotePublicKeyHex.equals(remotePublicKeyHex)))
        .getSingleOrNull();
  }

  /// Add contact to address book
  Future<void> addContact({
    required String displayName,
    required String ed25519PublicKeyHex,
    String? x25519PublicKeyHex,
    String? mlkemPublicKeyHex,
  }) async {
    await into(contacts).insert(
      ContactsCompanion(
        displayName: Value(displayName),
        ed25519PublicKeyHex: Value(ed25519PublicKeyHex),
        x25519PublicKeyHex: Value(x25519PublicKeyHex),
        mlkemPublicKeyHex: Value(mlkemPublicKeyHex),
        addedAt: Value(DateTime.now().microsecondsSinceEpoch * 1000),
      ),
    );
  }

  /// Close database connection
  Future<void> closeDatabase() async {
    await close();
    _instance = null;
  }
}

/// Extension for creating database connection with encryption
extension on String {
  DatabaseExecutor openEncrypted(String encryptionKey) {
    final sqliteDb = sqlite3.open(this);
    sqliteDb.execute("PRAGMA key='$encryptionKey';");
    return DatabaseConnection(sqliteDb);
  }
}
