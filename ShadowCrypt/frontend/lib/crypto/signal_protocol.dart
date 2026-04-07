/// Implements Signal Protocol (Double Ratchet) for forward secrecy
library signal_protocol;

import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

// ============================================================================
// SIGNAL PROTOCOL: KEY RATCHETING
// ============================================================================

/// Represents the state of Signal Protocol's Double Ratchet for a conversation
class SignalRatchetState {
  /// Root key for key derivation (KDF_ROOT)
  late Uint8List rootKey;

  /// Sender's chain key (for outgoing messages)
  late Uint8List senderChainKey;

  /// Receiver's chain key (for incoming messages)
  late Uint8List receiverChainKey;

  /// Current sender message key
  late Uint8List senderMessageKey;

  /// Current receiver message key
  late Uint8List receiverMessageKey;

  /// ECDH ephemeral key pair
  late Uint8List ourEphemeralPrivateKey;
  late Uint8List ourEphemeralPublicKey;
  late Uint8List? theirEphemeralPublicKey;

  /// Message counters for replay protection
  int senderMessageNumber = 0;
  int receiverMessageNumber = 0;

  SignalRatchetState({
    required this.rootKey,
    required this.senderChainKey,
    this.receiverChainKey = const [],
    required this.ourEphemeralPrivateKey,
    required this.ourEphemeralPublicKey,
  });

  /// Serializes state to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'rootKey': rootKey,
      'senderChainKey': senderChainKey,
      'receiverChainKey': receiverChainKey,
      'senderMessageKey': senderMessageKey,
      'receiverMessageKey': receiverMessageKey,
      'ourEphemeralPrivateKey': ourEphemeralPrivateKey,
      'ourEphemeralPublicKey': ourEphemeralPublicKey,
      'theirEphemeralPublicKey': theirEphemeralPublicKey,
      'senderMessageNumber': senderMessageNumber,
      'receiverMessageNumber': receiverMessageNumber,
    };
  }
}

// ============================================================================
// KDF CHAIN: Derives keys from chain keys (KDF_CK)
// ============================================================================

/// Key derivation function for chain ratcheting
class KdfChain {
  /// HMAC-SHA256 based KDF for chain key advancement
  /// 
  /// Output: (messageKey, chainKey) pair
  static Future<(Uint8List messageKey, Uint8List chainKey)> kdfChain({
    required Uint8List chainKey,
  }) async {
    final hmac = Hmac(Sha256());
    
    // KDF_CK(chainKey) = pair (messageKey, chainKey)
    // messageKey = HMAC-SHA256(key=chainKey, message=0x01)
    // newChainKey = HMAC-SHA256(key=chainKey, message=0x02)
    
    final messageKeyBytes = await hmac.calculateMac(
      [0x01],
      secretKey: SecretKey(chainKey),
    );
    final messageKey = Uint8List.fromList(messageKeyBytes.bytes);

    final newChainKeyBytes = await hmac.calculateMac(
      [0x02],
      secretKey: SecretKey(chainKey),
    );
    final newChainKey = Uint8List.fromList(newChainKeyBytes.bytes);

    return (messageKey, newChainKey);
  }

  /// HMAC-SHA256 based KDF for root key derivation (KDF_RK)
  /// 
  /// Called during DH ratchet step
  static Future<(Uint8List rootKey, Uint8List chainKey)> kdfRk({
    required Uint8List rootKey,
    required Uint8List dhOutput,
  }) async {
    final hmac = Hmac(Sha256());
    
    // KDF_RK(rootKey, dhOutput) = pair (newRootKey, newChainKey)
    // newRootKey = HMAC-SHA256(key=rootKey, message=0x01 || dhOutput)
    // newChainKey = HMAC-SHA256(key=rootKey, message=0x02 || dhOutput)
    
    final rootKeyInput = [...[0x01], ...dhOutput];
    final rootKeyBytes = await hmac.calculateMac(
      rootKeyInput,
      secretKey: SecretKey(rootKey),
    );
    final newRootKey = Uint8List.fromList(rootKeyBytes.bytes);

    final chainKeyInput = [...[0x02], ...dhOutput];
    final chainKeyBytes = await hmac.calculateMac(
      chainKeyInput,
      secretKey: SecretKey(rootKey),
    );
    final newChainKey = Uint8List.fromList(chainKeyBytes.bytes);

    return (newRootKey, newChainKey);
  }
}

// ============================================================================
// MESSAGE KEY: Derives AEAD and authentication keys from message key
// ============================================================================

/// Derives encryption and MAC keys from Signal Protocol message key
class MessageKeyDerivation {
  /// Derives AES-256 key and HMAC key from message key
  static Future<(Uint8List cipherKey, Uint8List macKey, Uint8List iv)> 
      kdfMessageKeys({
    required Uint8List messageKey,
  }) async {
    final hmac = Hmac(Sha256());
    
    // KDF_MK(messageKey) produces:
    // - 32 bytes for AES-256 cipher key
    // - 32 bytes for HMAC-SHA256 key
    // - 16 bytes for IV
    
    final cipherKeyBytes = await hmac.calculateMac(
      [0x01],
      secretKey: SecretKey(messageKey),
    );
    final cipherKey = Uint8List.fromList(cipherKeyBytes.bytes);

    final macKeyBytes = await hmac.calculateMac(
      [0x02],
      secretKey: SecretKey(messageKey),
    );
    final macKey = Uint8List.fromList(macKeyBytes.bytes);

    final ivBytes = await hmac.calculateMac(
      [0x03],
      secretKey: SecretKey(messageKey),
    );
    // Use only first 16 bytes for IV
    final iv = Uint8List.view(ivBytes.bytes.buffer, 0, 16);

    return (cipherKey, macKey, iv);
  }
}

// ============================================================================
// DOUBLE RATCHET PROTOCOL
// ============================================================================

/// Core Signal Protocol Double Ratchet implementation
class DoubleRatchet {
  SignalRatchetState state;

  DoubleRatchet(this.state);

  /// Performs symmetric ratchet for sending next message
  /// Advances sender chain key and derives message key
  Future<Uint8List> ratchetSenderMessageKey() async {
    final (messageKey, newChainKey) = 
        await KdfChain.kdfChain(chainKey: state.senderChainKey);
    
    state.senderChainKey = newChainKey;
    state.senderMessageNumber++;
    
    return messageKey;
  }

  /// Performs symmetric ratchet for receiving incoming message
  Future<Uint8List> ratchetReceiverMessageKey() async {
    final (messageKey, newChainKey) = 
        await KdfChain.kdfChain(chainKey: state.receiverChainKey);
    
    state.receiverChainKey = newChainKey;
    state.receiverMessageNumber++;
    
    return messageKey;
  }

  /// Performs DH ratchet (Diffie-Hellman ratchet)
  /// Called when DH ephemeral keys are updated
  /// 
  /// Parameters:
  /// - theirNewPublicKey: Recipient's new ephemeral DH public key
  /// - ourNewEphemeralPrivateKey: Our newly generated ephemeral private key
  Future<void> ratchetDH({
    required Uint8List theirNewPublicKey,
    required Uint8List ourNewEphemeralPrivateKey,
    required Uint8List ourNewEphemeralPublicKey,
  }) async {
    // Compute shared secret using X25519
    // dhOutput = ECDH(ourEphemeralPrivateKey, theirEphemeralPublicKey)
    // This requires X25519 implementation
    
    // For now, placeholder
    final dhOutput = Uint8List(32); // Replace with actual DH computation

    // Derive new root key and chain key
    final (newRootKey, newChainKey) = await KdfChain.kdfRk(
      rootKey: state.rootKey,
      dhOutput: dhOutput,
    );

    state.rootKey = newRootKey;
    state.senderChainKey = newChainKey;
    state.receiverChainKey = Uint8List(32); // Reset receiver chain
    state.theirEphemeralPublicKey = theirNewPublicKey;
    state.ourEphemeralPrivateKey = ourNewEphemeralPrivateKey;
    state.ourEphemeralPublicKey = ourNewEphemeralPublicKey;
  }
}
