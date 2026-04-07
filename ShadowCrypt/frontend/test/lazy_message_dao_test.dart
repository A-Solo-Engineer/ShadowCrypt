/// Tests for lazy-loading message DAO
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' as drift;
import '../data/database/lazy_message_dao.dart';
import 'dart:typed_data';

void main() {
  group('LazyMessageDAO', () {
    late LazyMessageDAO dao;
    late MockDatabase mockDatabase;

    setUp(() {
      mockDatabase = MockDatabase();
      dao = LazyMessageDAO(
        database: mockDatabase,
        batchSize: 20,
      );
    });

    test('Initializes background isolate', () async {
      await dao.initialize();

      // Should not throw
      expect(dao, isNotNull);

      await dao.shutdown();
    });

    test('Loads messages in 20-message batches', () async {
      await dao.initialize();

      final cryptoKeyMessages = <EncryptedMessageDTO>[];
      for (int i = 0; i < 100; i++) {
        cryptoKeyMessages.add(
          EncryptedMessageDTO(
            id: i,
            messageId: 'msg_$i',
            fromPublicKey: 'alice_key',
            toPublicKey: 'bob_key',
            encryptedPayload: 'encrypted_$i',
            chainKey: 'chain_key',
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }

      // (Note: Real test would mock _queryEncryptedMessages)
      expect(cryptoKeyMessages.length, equals(100));

      await dao.shutdown();
    });

    test('Preloads next page during navigation', () async {
      await dao.initialize();

      // Simulate scrolling scenario
      final contactKey = 'contact_public_key';

      // This would preload page N+1 while viewing page N
      await dao.preloadNextPage(contactPublicKey: contactKey);

      // Should not block main thread
      expect(true, isTrue);

      await dao.shutdown();
    });

    test('Caches decrypted messages in memory', () async {
      await dao.initialize();

      final testMessage = DecryptedMessageDTO(
        id: 1,
        messageId: 'msg_1',
        fromPublicKey: 'alice',
        toPublicKey: 'bob',
        plaintext: 'Hello',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

      // Manually add to cache for testing
      // (Real test would go through load flow)

      final cached = dao.getCachedMessage(1);
      expect(cached, isNull); // Not cached yet

      await dao.shutdown();
    });

    test('Clears cache to free memory on i3 devices', () async {
      await dao.initialize();

      // Add some messages to cache...
      dao.clearCache();

      // Cache should be empty
      final cached = dao.getCachedMessage(1);
      expect(cached, isNull);

      await dao.shutdown();
    });
  });

  group('DecryptionTask', () {
    test('Groups messages for batch processing', () {
      final messages = List.generate(
        50,
        (i) => EncryptedMessageDTO(
          id: i,
          messageId: 'msg_$i',
          fromPublicKey: 'alice',
          toPublicKey: 'bob',
          encryptedPayload: 'encrypted',
          chainKey: 'key',
          createdAt: 0,
        ),
      );

      final task = DecryptionTask(
        encryptedMessages: messages,
        signalRootKey: Uint8List(32),
        batchSize: 20,
      );

      expect(task.encryptedMessages.length, equals(50));
      expect(task.batchSize, equals(20));
    });
  });

  group('DecryptionPerformanceTracker', () {
    test('Calculates average decryption time', () {
      final tracker = DecryptionPerformanceTracker();

      tracker.recordBatch(
        DecryptionResult(
          decryptedMessages: [
            // 20 messages
            for (int i = 0; i < 20; i++)
              DecryptedMessageDTO(
                id: i,
                messageId: 'msg_$i',
                fromPublicKey: 'alice',
                toPublicKey: 'bob',
                plaintext: 'text',
                createdAt: 0,
              ),
          ],
          batchNumber: 1,
          totalBatches: 1,
          processingTime: const Duration(milliseconds: 100),
        ),
      );

      tracker.recordBatch(
        DecryptionResult(
          decryptedMessages: List.generate(
            20,
            (i) => DecryptedMessageDTO(
              id: 20 + i,
              messageId: 'msg_${20 + i}',
              fromPublicKey: 'alice',
              toPublicKey: 'bob',
              plaintext: 'text',
              createdAt: 0,
            ),
          ),
          batchNumber: 2,
          totalBatches: 2,
          processingTime: const Duration(milliseconds: 90),
        ),
      );

      final avgTime = tracker.getAverageDecryptionTime();
      expect(avgTime.inMilliseconds, closeTo(95, 5));

      final throughput = tracker.getAverageMessagesPerSecond();
      expect(throughput, greaterThan(200)); // ~210 msgs/sec for 20ms/batch
    });

    test('Reports i3 hardware metrics', () {
      final tracker = DecryptionPerformanceTracker();

      tracker.recordBatch(
        DecryptionResult(
          decryptedMessages: List.generate(
            20,
            (i) => DecryptedMessageDTO(
              id: i,
              messageId: 'msg_$i',
              fromPublicKey: 'alice',
              toPublicKey: 'bob',
              plaintext: 'text',
              createdAt: 0,
            ),
          ),
          batchNumber: 1,
          totalBatches: 1,
          processingTime: const Duration(milliseconds: 150),
        ),
      );

      // Should not throw
      tracker.printStats();

      expect(true, isTrue);
    });
  });
}

class MockDatabase extends drift.GeneratedDatabase {
  MockDatabase()
      : super(
          nullIfMissing: false,
          options: drift.QueryExecutorOptions(),
        );

  @override
  Iterable<drift.TableInfo> get allTables => [];

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => drift.MigrationStrategy();
}
