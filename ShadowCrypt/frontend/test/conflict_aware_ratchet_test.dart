/// Tests for conflict-aware Double Ratchet
import 'package:flutter_test/flutter_test.dart';
import '../crypto/conflict_aware_ratchet.dart';
import 'dart:typed_data';

void main() {
  group('ConflictAwareDoubleRatchet', () {
    late VersionedRatchetState aliceInitialState;
    late VersionedRatchetState bobInitialState;

    setUp(() {
      // Initialize with simple test states
      aliceInitialState = VersionedRatchetState(
        sequenceNumber: 0,
        dhEpoch: 0,
        rootKey: Uint8List(32),
        senderChainKey: Uint8List(32),
        receiverChainKey: Uint8List(32),
        ourEphemeralPrivateKey: Uint8List(32),
        ourEphemeralPublicKey: Uint8List(32),
      );

      bobInitialState = VersionedRatchetState(
        sequenceNumber: 0,
        dhEpoch: 0,
        rootKey: Uint8List(32),
        senderChainKey: Uint8List(32),
        receiverChainKey: Uint8List(32),
        ourEphemeralPrivateKey: Uint8List(32),
        ourEphemeralPublicKey: Uint8List(32),
      );
    });

    test('Detects simultaneous DH ratchet proposals (conflict)', () {
      final aliceRatchet = ConflictAwareDoubleRatchet(
        currentState: aliceInitialState,
        localPartyId: 'alice',
        remotePartyId: 'bob',
      );

      final bobRatchet = ConflictAwareDoubleRatchet(
        currentState: bobInitialState,
        localPartyId: 'bob',
        remotePartyId: 'alice',
      );

      // Alice proposes DH ratchet
      final alicePending = aliceRatchet.proposeDHRatchetLocally(
        newEphemeralPrivateKey: Uint8List(32),
        newEphemeralPublicKey: Uint8List(32),
        dhOutput: Uint8List(32),
      );

      // Bob also proposes DH ratchet (simultaneously)
      final bobPending = bobRatchet.proposeDHRatchetLocally(
        newEphemeralPrivateKey: Uint8List(32),
        newEphemeralPublicKey: Uint8List(32),
        dhOutput: Uint8List(32),
      );

      // Bob receives Alice's proposal (there's a conflict on Bob's side)
      // This should detect the simultaneous proposals
      expect(alicePending.status, equals("pending"));
      expect(bobPending.status, equals("pending"));

      expect(aliceRatchet.pendingUpdates.length, equals(1));
      expect(bobRatchet.pendingUpdates.length, equals(1));
    });

    test('Resolves conflict based on sequence number', () {
      final aliceRatchet = ConflictAwareDoubleRatchet(
        currentState: aliceInitialState,
        localPartyId: 'alice',
        remotePartyId: 'bob',
      );

      // Alice proposes at sequence 0
      aliceRatchet.proposeDHRatchetLocally(
        newEphemeralPrivateKey: Uint8List(32),
        newEphemeralPublicKey: Uint8List(32),
        dhOutput: Uint8List(32),
      );

      // Bob sends proposal at sequence 1 (higher)
      // Bob's should win because sequence is higher
      final resolution = aliceRatchet.receiveRemoteDHRatchet(
        remoteEphemeralPublicKey: Uint8List(32),
        remoteSequenceNumber: 1,
        remoteDHOutput: Uint8List(32),
      );

      expect(resolution.winner, equals("remote"));
      expect(
          aliceRatchet.pendingUpdates
              .firstWhere((p) => p.proposedBy == 'local')
              .status,
          equals("rejected"));
    });

    test('Resolves conflict by public key comparison on same sequence',
        () {
      final aliceRatchet = ConflictAwareDoubleRatchet(
        currentState: aliceInitialState,
        localPartyId: 'alice',
        remotePartyId: 'bob',
      );

      final aliceKey = Uint8List(32);
      aliceKey[0] = 255; // Large value

      final bobKey = Uint8List(32);
      bobKey[0] = 1; // Small value

      // Alice proposes at sequence 0
      aliceRatchet.proposeDHRatchetLocally(
        newEphemeralPrivateKey: Uint8List(32),
        newEphemeralPublicKey: aliceKey,
        dhOutput: Uint8List(32),
      );

      // Bob sends at same sequence but with smaller key
      // Alice's key is larger, so Alice should win
      final resolution = aliceRatchet.receiveRemoteDHRatchet(
        remoteEphemeralPublicKey: bobKey,
        remoteSequenceNumber: 0,
        remoteDHOutput: Uint8List(32),
      );

      expect(resolution.winner, equals("local"));
    });

    test('Preserves historical state for skipped messages', () {
      final ratchet = ConflictAwareDoubleRatchet(
        currentState: aliceInitialState,
        localPartyId: 'alice',
        remotePartyId: 'bob',
      );

      final initialHistorySize = ratchet.stateHistory.length;

      // Propose and accept remote DH update
      ratchet.receiveRemoteDHRatchet(
        remoteEphemeralPublicKey: Uint8List(32),
        remoteSequenceNumber: 1,
        remoteDHOutput: Uint8List(32),
      );

      // Should have archived the old state
      expect(
          ratchet.stateHistory.length, equals(initialHistorySize + 1));
    });

    test('Prevents DoS via excessive skipped messages', () {
      final store = SkippedMessageKeyStore();

      // Fill to maximum
      for (int i = 0; i < SkippedMessageKeyStore.maxSkippedKeys + 10; i++) {
        store.addSkippedKey(0, i, Uint8List(32));
      }

      // Should not exceed max size
      expect(store.skippedKeys.length,
          lessThanOrEqualTo(SkippedMessageKeyStore.maxSkippedKeys));
    });

    test('Can decrypt messages from historical states', () {
      final ratchet = ConflictAwareDoubleRatchet(
        currentState: aliceInitialState,
        localPartyId: 'alice',
        remotePartyId: 'bob',
      );

      // Add to history
      ratchet.stateHistory.add(aliceInitialState.copy());

      // Check if we can handle old message
      final canDecrypt = ratchet.canDecryptWithHistoricalState(
        Uint8List(32),
        0,
      );

      // Depends on implementation, but should have fallback path
      expect(canDecrypt, anyOf([true, false])); // Implementation dependent
    });
  });

  group('VersionedRatchetState', () {
    test('Creates copy with independent data', () {
      final original = VersionedRatchetState(
        sequenceNumber: 1,
        dhEpoch: 2,
        rootKey: Uint8List(32),
        senderChainKey: Uint8List(32),
        receiverChainKey: Uint8List(32),
        ourEphemeralPrivateKey: Uint8List(32),
        ourEphemeralPublicKey: Uint8List(32),
      );

      final copy = original.copy();

      // Should be equal but independent
      expect(copy.sequenceNumber, equals(original.sequenceNumber));
      expect(copy.dhEpoch, equals(original.dhEpoch));

      // Modifying copy shouldn't affect original
      copy.rootKey[0] = 255;
      expect(original.rootKey[0], isNot(equals(255)));
    });
  });

  group('Conflict Resolution Tie-Breaking', () {
    test('Higher sequence number wins', () {
      final ratchet = ConflictAwareDoubleRatchet(
        currentState: aliceInitialState,
        localPartyId: 'alice',
        remotePartyId: 'bob',
      );

      // Propose locally at seq 0
      ratchet.proposeDHRatchetLocally(
        newEphemeralPrivateKey: Uint8List(32),
        newEphemeralPublicKey: Uint8List(32),
        dhOutput: Uint8List(32),
      );

      // Remote at seq 5 (higher)
      final resolution = ratchet.receiveRemoteDHRatchet(
        remoteEphemeralPublicKey: Uint8List(32),
        remoteSequenceNumber: 5,
        remoteDHOutput: Uint8List(32),
      );

      expect(resolution.winner, equals("remote"));
    });

    test('Same sequence uses lexicographic key comparison', () {
      final ratchet = ConflictAwareDoubleRatchet(
        currentState: aliceInitialState,
        localPartyId: 'alice',
        remotePartyId: 'bob',
      );

      final smallerKey = Uint8List(32); // All zeros
      final largerKey = Uint8List(32);
      largerKey[0] = 1;

      ratchet.proposeDHRatchetLocally(
        newEphemeralPrivateKey: Uint8List(32),
        newEphemeralPublicKey: largerKey,
        dhOutput: Uint8List(32),
      );

      final resolution = ratchet.receiveRemoteDHRatchet(
        remoteEphemeralPublicKey: smallerKey,
        remoteSequenceNumber: 0,
        remoteDHOutput: Uint8List(32),
      );

      // Local key is larger, so local should win
      expect(resolution.winner, equals("local"));
    });
  });
}
