/// Cryptographic key management and operations for ShadowCrypt
library crypto;

import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart';
import 'package:bip39/bip39.dart' as bip39;
import 'package:convert/convert.dart';

// ============================================================================
// MNEMONIC & KEY DERIVATION
// ============================================================================

/// Generates a new 12-word BIP-39 mnemonic for recovery
class MnemonicGenerator {
  /// Generate a cryptographically secure 12-word mnemonic
  static String generate12WordMnemonic() {
    return bip39.generateMnemonic(strength: 128); // 12 words
  }

  /// Validate if a mnemonic is valid BIP-39
  static bool isValidMnemonic(String mnemonic) {
    return bip39.validateMnemonic(mnemonic);
  }

  /// Convert mnemonic to entropy bytes
  static Uint8List mnemonicToEntropy(String mnemonic) {
    final entropy = bip39.mnemonicToEntropy(mnemonic);
    return Uint8List.fromList(hex.decode(entropy));
  }

  /// Convert entropy back to mnemonic
  static String entropyToMnemonic(Uint8List entropy) {
    return bip39.entropyToMnemonic(hex.encode(entropy));
  }
}

// ============================================================================
// ENCRYPTION KEY DERIVATION
// ============================================================================

/// Derives encryption keys from BIP-39 mnemonic
class KeyDerivation {
  /// Derives a 32-byte AES-256 key from mnemonic using PBKDF2-SHA256
  /// 
  /// Parameters:
  /// - mnemonic: Valid 12-word BIP-39 mnemonic
  /// - salt: Optional custom salt (default: "shadowcrypt")
  /// - iterations: PBKDF2 iterations (default: 100,000 for security)
  /// - length: Output key length in bytes (default: 32 for AES-256)
  static Future<Uint8List> deriveEncryptionKey({
    required String mnemonic,
    String salt = "shadowcrypt_encryption",
    int iterations = 100000,
    int length = 32,
  }) async {
    // Validate mnemonic
    if (!MnemonicGenerator.isValidMnemonic(mnemonic)) {
      throw ArgumentError("Invalid BIP-39 mnemonic");
    }

    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac(Sha256()),
      iterations: iterations,
    );

    final key = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(mnemonic)),
      nonce: utf8.encode(salt),
      keyLength: length,
    );

    return Uint8List.fromList(await key.extractBytes());
  }

  /// Derives an Ed25519 identity keypair from mnemonic
  static Future<Map<String, Uint8List>> deriveIdentityKeypair({
    required String mnemonic,
  }) async {
    // Use BIP-39 seed derivation
    final seed = bip39.mnemonicToSeed(mnemonic);
    final seedBytes = Uint8List.fromList(hex.decode(seed));

    // Use first 32 bytes as Ed25519 private key seed
    final privateKeySeed = seedBytes.sublist(0, 32);

    // Generate Ed25519 keypair from seed
    // This requires ed25519 implementation - use PointyCastle or cryptography package
    // For now, this is a placeholder

    return {
      "privateKey": privateKeySeed,
      // Public key would be derived from private key using Ed25519
    };
  }

  /// Derives X25519 ECDHE keypair from mnemonic for initial key exchange
  static Future<Map<String, Uint8List>> deriveX25519Keypair({
    required String mnemonic,
  }) async {
    final seed = bip39.mnemonicToSeed(mnemonic);
    final seedBytes = Uint8List.fromList(hex.decode(seed));

    // Use bytes 32-64 for X25519 private key
    final privateKey = seedBytes.sublist(32, 64);

    return {
      "privateKey": privateKey,
      // Public key derived using X25519
    };
  }
}

// ============================================================================
// SYMMETRIC ENCRYPTION (AES-256-GCM)
// ============================================================================

/// Handles AES-256-GCM encryption for message payloads
class MessageEncryption {
  /// Encrypts a message using AES-256-GCM
  static Future<String> encryptMessage({
    required String plaintext,
    required Uint8List key,
    String? associatedData,
  }) async {
    if (key.length != 32) {
      throw ArgumentError("Key must be 32 bytes for AES-256");
    }

    final cipher = AesGcm.with256bits();
    final nonce = Uint8List(12); // 96-bit nonce (zero for determinism - use random in production)
    
    // In production, use random nonce and prepend to ciphertext
    final secretKey = SecretKey(key);
    
    final encrypted = await cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
      aadBytes: associatedData != null ? utf8.encode(associatedData) : null,
    );

    // Return ciphertext + tag as base64
    return base64.encode(encrypted.cipherText + encrypted.mac.bytes);
  }

  /// Decrypts an AES-256-GCM encrypted message
  static Future<String> decryptMessage({
    required String ciphertext,
    required Uint8List key,
    String? associatedData,
  }) async {
    if (key.length != 32) {
      throw ArgumentError("Key must be 32 bytes for AES-256");
    }

    final cipher = AesGcm.with256bits();
    final nonce = Uint8List(12);
    
    final secretKey = SecretKey(key);
    final ciphertextBytes = base64.decode(ciphertext);

    // Split ciphertext and tag
    final actualCiphertext = ciphertextBytes.sublist(0, ciphertextBytes.length - 16);
    final tag = ciphertextBytes.sublist(ciphertextBytes.length - 16);

    try {
      final decrypted = await cipher.decrypt(
        AesGcmSecretBox(actualCiphertext, nonce: nonce, mac: Mac(tag)),
        secretKey: secretKey,
        aadBytes: associatedData != null ? utf8.encode(associatedData) : null,
      );

      return utf8.decode(decrypted);
    } catch (e) {
      throw Exception("Decryption failed: $e");
    }
  }
}

// ============================================================================
// HELPER IMPORTS
// ============================================================================

import 'dart:convert';

// Extensions for hex encoding
import 'package:convert/convert.dart' as convert;
