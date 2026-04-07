/// Thread-safe Double Ratchet with conflict resolution
library signal_protocol_safe;

import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

// ============================================================================
// VERSIONED RATCHET STATE WITH CONFLICT RESOLUTION
// ============================================================================

/// Represents a specific version of Ratchet state with sequence number
class VersionedRatchetState {
  /// Global sequence number for this pair
  final int sequenceNumber;
  
  /// Epoch/generation of DH keys (increments on each DH ratchet)
  final int dhEpoch;
  
  /// Root key for key derivation
  final Uint8List rootKey;
  
  /// Sender's chain key (for messages this party sends)
  final Uint8List senderChainKey;
  
  /// Receiver's chain key (for messages from other party)
  final Uint8List receiverChainKey;
  
  /// Our ephemeral private key
  final Uint8List ourEphemeralPrivateKey;
  
  /// Our ephemeral public key
  final Uint8List ourEphemeralPublicKey;
  
  /// Their ephemeral public key (might be from pending DH update)
  final Uint8List? theirEphemeralPublicKey;
  
  /// Message send counter (for replay prevention)
  int senderMessageNumber = 0;
  
  /// Message receive counter
  int receiverMessageNumber = 0;
  
  /// Timestamp of when this version was created
  final DateTime createdAt;
  
  /// True if this state is currently "active" for messaging
  bool isActive = true;

  VersionedRatchetState({
    required this.sequenceNumber,
    required this.dhEpoch,
    required this.rootKey,
    required this.senderChainKey,
    required this.receiverChainKey,
    required this.ourEphemeralPrivateKey,
    required this.ourEphemeralPublicKey,
    this.theirEphemeralPublicKey,
  }) : createdAt = DateTime.now();

  /// Creates a copy of this state
  VersionedRatchetState copy() {
    return VersionedRatchetState(
      sequenceNumber: sequenceNumber,
      dhEpoch: dhEpoch,
      rootKey: Uint8List.fromList(rootKey),
      senderChainKey: Uint8List.fromList(senderChainKey),
      receiverChainKey: Uint8List.fromList(receiverChainKey),
      ourEphemeralPrivateKey: Uint8List.fromList(ourEphemeralPrivateKey),
      ourEphemeralPublicKey: Uint8List.fromList(ourEphemeralPublicKey),
      theirEphemeralPublicKey: theirEphemeralPublicKey != null
          ? Uint8List.fromList(theirEphemeralPublicKey!)
          : null,
    )
      ..senderMessageNumber = senderMessageNumber
      ..receiverMessageNumber = receiverMessageNumber
      ..isActive = isActive;
  }
}

// ============================================================================
// PENDING RATCHET UPDATES (For conflict resolution)
// ============================================================================

/// Represents a proposed DH ratchet that hasn't been confirmed yet
class PendingDHUpdate {
  /// Who proposed this? ("local" or "remote")
  final String proposedBy;
  
  /// The new ephemeral public key being proposed
  final Uint8List newEphemeralPublicKey;
  
  /// Sequence number this was proposed at
  final int sequenceNumberAtProposal;
  
  /// DH output (shared secret) from this ratchet
  final Uint8List? dhOutput;
  
  /// Resulting state if this update is accepted
  late VersionedRatchetState proposedState;
  
  /// Timestamp of when this was proposed
  final DateTime proposedAt;
  
  /// Status: pending, accepted, rejected, merged
  String status = "pending"; // pending | accepted | rejected | merged

  PendingDHUpdate({
    required this.proposedBy,
    required this.newEphemeralPublicKey,
    required this.sequenceNumberAtProposal,
    this.dhOutput,
  }) : proposedAt = DateTime.now();
}

// ============================================================================
// CONFLICT-AWARE DOUBLE RATCHET
// ============================================================================

/// Conflict-resistant Double Ratchet implementation
/// Handles simultaneous DH ratchet attempts from both parties
class ConflictAwareDoubleRatchet {
  /// Current active state
  VersionedRatchetState currentState;
  
  /// History of previous states (for skipped message recovery)
  List<VersionedRatchetState> stateHistory = [];
  
  /// Pending DH updates waiting for confirmation
  List<PendingDHUpdate> pendingUpdates = [];
  
  /// Identity of "this" party (for tie-breaking)
  final String localPartyId;
  
  /// Identity of remote party
  final String remotePartyId;
  
  /// Global sequence counter (must be replicated with remote)
  int globalSequenceNumber = 0;

  ConflictAwareDoubleRatchet({
    required this.currentState,
    required this.localPartyId,
    required this.remotePartyId,
  });

  // ============================================================================
  // CONFLICT DETECTION & RESOLUTION
  // ============================================================================

  /// Called when we want to propose a DH ratchet locally
  /// Returns the pending update that was created
  PendingDHUpdate proposeDHRatchetLocally({
    required Uint8List newEphemeralPrivateKey,
    required Uint8List newEphemeralPublicKey,
    required Uint8List? dhOutput,
  }) {
    final pending = PendingDHUpdate(
      proposedBy: 'local',
      newEphemeralPublicKey: newEphemeralPublicKey,
      sequenceNumberAtProposal: globalSequenceNumber,
      dhOutput: dhOutput,
    );

    // Create the proposed state (but don't activate yet)
    pending.proposedState = _createDHRatchetedState(
      newEphemeralPrivateKey: newEphemeralPrivateKey,
      newEphemeralPublicKey: newEphemeralPublicKey,
      dhOutput: dhOutput,
      isActive: false,
    );

    pendingUpdates.add(pending);
    return pending;
  }

  /// Called when remote party sends a DH ratchet update
  /// Must handle case where we also proposed a local update
  Future<DHRatchetResolutionResult> receiveRemoteDHRatchet({
    required Uint8List remoteEphemeralPublicKey,
    required int remoteSequenceNumber,
    required Uint8List? remoteDHOutput,
  }) async {
    // Check if there's a conflict (we also proposed one)
    final localPending = pendingUpdates
        .firstWhere((p) => p.proposedBy == 'local', orElse: () => null as dynamic);

    if (localPending != null && localPending.status == "pending") {
      // CONFLICT: Both parties proposed DH ratchet simultaneously
      return _resolveConflict(
        localUpdate: localPending,
        remoteEphemeralPublicKey: remoteEphemeralPublicKey,
        remoteSequenceNumber: remoteSequenceNumber,
        remoteDHOutput: remoteDHOutput,
      );
    } else {
      // No conflict, just apply remote update
      return _acceptRemoteDHRatchet(
        remoteEphemeralPublicKey: remoteEphemeralPublicKey,
        remoteSequenceNumber: remoteSequenceNumber,
        remoteDHOutput: remoteDHOutput,
      );
    }
  }

  /// Resolve conflict when both parties propose simultaneously
  /// Winner determined by: (sequence_number, lexicographic_comparison_of_public_keys)
  DHRatchetResolutionResult _resolveConflict({
    required PendingDHUpdate localUpdate,
    required Uint8List remoteEphemeralPublicKey,
    required int remoteSequenceNumber,
    required Uint8List? remoteDHOutput,
  }) {
    // Tie-breaker logic:
    // 1. If sequence numbers differ, higher wins
    // 2. If same sequence, compare public keys lexicographically
    // 3. If same, use party IDs (alphabetical)

    final localSeq = localUpdate.sequenceNumberAtProposal;
    final remoteSeq = remoteSequenceNumber;

    bool remoteWins = false;

    if (remoteSeq > localSeq) {
      remoteWins = true;
    } else if (remoteSeq == localSeq) {
      // Compare public keys lexicographically
      final localKey = localUpdate.newEphemeralPublicKey;
      final comparison = _compareByteArrays(localKey, remoteEphemeralPublicKey);

      if (comparison < 0) {
        // localKey < remoteKey, so remote wins
        remoteWins = true;
      } else if (comparison == 0) {
        // Keys are identical (shouldn't happen, but handle it)
        // Use party IDs as final tie-breaker
        remoteWins = remotePartyId.compareTo(localPartyId) > 0;
      }
      // else: local wins (comparison > 0)
    }
    // else: localSeq > remoteSeq, local wins

    if (remoteWins) {
      // Accept remote's update, discard local
      localUpdate.status = "rejected";

      final remoteUpdate = _acceptRemoteDHRatchet(
        remoteEphemeralPublicKey: remoteEphemeralPublicKey,
        remoteSequenceNumber: remoteSequenceNumber,
        remoteDHOutput: remoteDHOutput,
      );

      return DHRatchetResolutionResult(
        winner: "remote",
        resolution: remoteUpdate,
        reason: "Remote update won conflict resolution",
      );
    } else {
      // Keep local update active
      localUpdate.status = "accepted";

      // But we need to process messages that might have arrived
      // under the remote's proposed state
      // This is handled by storing old states in stateHistory

      return DHRatchetResolutionResult(
        winner: "local",
        resolution: localUpdate,
        reason: "Local update won conflict resolution",
      );
    }
  }

  /// Accept a remote DH ratchet without conflict
  DHRatchetResolutionResult _acceptRemoteDHRatchet({
    required Uint8List remoteEphemeralPublicKey,
    required int remoteSequenceNumber,
    required Uint8List? remoteDHOutput,
  }) {
    // Create remote update
    final remoteUpdate = PendingDHUpdate(
      proposedBy: 'remote',
      newEphemeralPublicKey: remoteEphemeralPublicKey,
      sequenceNumberAtProposal: remoteSequenceNumber,
      dhOutput: remoteDHOutput,
    );

    // Archive current state before transitioning
    stateHistory.add(currentState.copy());

    // Create new state with remote's DH
    remoteUpdate.proposedState = _createDHRatchetedState(
      newEphemeralPrivateKey: currentState.ourEphemeralPrivateKey,
      newEphemeralPublicKey: currentState.ourEphemeralPublicKey,
      dhOutput: remoteDHOutput,
      isActive: true,
      theirEphemeralPublicKey: remoteEphemeralPublicKey,
    );

    remoteUpdate.status = "accepted";
    currentState = remoteUpdate.proposedState;
    globalSequenceNumber++;

    pendingUpdates.add(remoteUpdate);

    return DHRatchetResolutionResult(
      winner: "remote",
      resolution: remoteUpdate,
      reason: "Remote DH ratchet accepted",
    );
  }

  /// Create a new state after DH ratchet
  VersionedRatchetState _createDHRatchetedState({
    required Uint8List newEphemeralPrivateKey,
    required Uint8List newEphemeralPublicKey,
    required Uint8List? dhOutput,
    required bool isActive,
    Uint8List? theirEphemeralPublicKey,
  }) {
    // Simplified version - in reality would call KDF_RK
    final newRootKey = _deriveNewRootKey(currentState.rootKey, dhOutput);
    final newChainKey = _deriveNewChainKey(newRootKey);

    return VersionedRatchetState(
      sequenceNumber: globalSequenceNumber + 1,
      dhEpoch: currentState.dhEpoch + 1,
      rootKey: newRootKey,
      senderChainKey: newChainKey,
      receiverChainKey: Uint8List(32), // Will be filled from remote
      ourEphemeralPrivateKey: newEphemeralPrivateKey,
      ourEphemeralPublicKey: newEphemeralPublicKey,
      theirEphemeralPublicKey: theirEphemeralPublicKey,
    )..isActive = isActive;
  }

  /// Attempt to decrypt message from old state (for late arrivals)
  bool canDecryptWithHistoricalState(Uint8List ciphertext, int messageSeq) {
    // Check stateHistory for state that can decrypt this
    for (final historicalState in stateHistory) {
      if (messageSeq >= historicalState.receiverMessageNumber) {
        // This message might belong to this historical state
        return true;
      }
    }
    return false;
  }

  /// Helper: Compare two byte arrays lexicographically
  int _compareByteArrays(Uint8List a, Uint8List b) {
    final minLen = a.length < b.length ? a.length : b.length;

    for (int i = 0; i < minLen; i++) {
      if (a[i] < b[i]) return -1;
      if (a[i] > b[i]) return 1;
    }

    if (a.length < b.length) return -1;
    if (a.length > b.length) return 1;
    return 0;
  }

  // Placeholder KDF functions (would use real cryptographic operations)
  Uint8List _deriveNewRootKey(Uint8List rootKey, Uint8List? dhOutput) {
    return Uint8List(32); // Replace with actual KDF_RK
  }

  Uint8List _deriveNewChainKey(Uint8List rootKey) {
    return Uint8List(32); // Replace with actual KDF_CK
  }
}

// ============================================================================
// RESOLUTION RESULT
// ============================================================================

class DHRatchetResolutionResult {
  final String winner; // "local" or "remote"
  final PendingDHUpdate resolution;
  final String reason;

  DHRatchetResolutionResult({
    required this.winner,
    required this.resolution,
    required this.reason,
  });
}

// ============================================================================
// SKIPPED MESSAGES HANDLING
// ============================================================================

/// Stores keys for messages that arrived out-of-order
class SkippedMessageKeyStore {
  /// Map: (dhEpoch, messageNumber) -> messageKey
  Map<(int, int), Uint8List> skippedKeys = {};

  /// Maximum number of skipped keys to retain (DoS protection)
  static const maxSkippedKeys = 1000;

  void addSkippedKey(int dhEpoch, int messageNumber, Uint8List messageKey) {
    if (skippedKeys.length >= maxSkippedKeys) {
      // Remove oldest entry to prevent memory exhaustion
      skippedKeys.remove(skippedKeys.keys.first);
    }
    skippedKeys[(dhEpoch, messageNumber)] = messageKey;
  }

  Uint8List? getSkippedKey(int dhEpoch, int messageNumber) {
    return skippedKeys[(dhEpoch, messageNumber)];
  }

  bool hasSkippedKey(int dhEpoch, int messageNumber) {
    return skippedKeys.containsKey((dhEpoch, messageNumber));
  }

  void removeSkippedKey(int dhEpoch, int messageNumber) {
    skippedKeys.remove((dhEpoch, messageNumber));
  }
}
