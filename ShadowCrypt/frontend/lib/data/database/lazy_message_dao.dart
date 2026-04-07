/// Background Isolate-based lazy message loading for i3 laptops
library lazy_message_dao;

import 'dart:async';
import 'dart:isolate';
import 'package:drift/drift.dart';
import 'package:cryptography/cryptography.dart';
import 'dart:typed_data';

// ============================================================================
// MESSAGE DECRYPTION ISOLATE
// ============================================================================

/// Message decryption task to be run in background isolate
class DecryptionTask {
  final List<EncryptedMessageDTO> encryptedMessages;
  final Uint8List signalRootKey;
  final int batchSize;

  DecryptionTask({
    required this.encryptedMessages,
    required this.signalRootKey,
    this.batchSize = 20,
  });
}

/// Result from background decryption
class DecryptionResult {
  final List<DecryptedMessageDTO> decryptedMessages;
  final int batchNumber;
  final int totalBatches;
  final Duration processingTime;

  DecryptionResult({
    required this.decryptedMessages,
    required this.batchNumber,
    required this.totalBatches,
    required this.processingTime,
  });
}

/// DTO for encrypted message from database
class EncryptedMessageDTO {
  final int id;
  final String messageId;
  final String fromPublicKey;
  final String toPublicKey;
  final String encryptedPayload; // base64
  final String chainKey; // hex
  final int createdAt;

  EncryptedMessageDTO({
    required this.id,
    required this.messageId,
    required this.fromPublicKey,
    required this.toPublicKey,
    required this.encryptedPayload,
    required this.chainKey,
    required this.createdAt,
  });
}

/// DTO for decrypted message
class DecryptedMessageDTO {
  final int id;
  final String messageId;
  final String fromPublicKey;
  final String toPublicKey;
  final String plaintext;
  final int createdAt;

  DecryptedMessageDTO({
    required this.id,
    required this.messageId,
    required this.fromPublicKey,
    required this.toPublicKey,
    required this.plaintext,
    required this.createdAt,
  });
}

// ============================================================================
// BACKGROUND ISOLATE DECRYPTION WORKER
// ============================================================================

/// Runs in a background isolate; processes message decryption batches
Future<void> _decryptionIsolateEntryPoint(SendPort sendPort) async {
  final receivePort = ReceivePort();
  sendPort.send(receivePort.sendPort);

  await for (final message in receivePort) {
    if (message is DecryptionTask) {
      try {
        final result = await _processDecryptionBatch(message);
        sendPort.send(result);
      } catch (e) {
        sendPort.send(DecryptionError(error: e.toString()));
      }
    }
  }
}

/// Processes a batch of encrypted messages in background isolate
Future<DecryptionResult> _processDecryptionBatch(DecryptionTask task) async {
  final startTime = DateTime.now();
  final decrypted = <DecryptedMessageDTO>[];

  // Group messages into batches of 20 for processing
  for (int i = 0; i < task.encryptedMessages.length; i++) {
    final msg = task.encryptedMessages[i];

    try {
      // Decrypt each message independently
      // In real implementation, would derive chain key and decrypt
      final plaintext = await _decryptMessage(
        encryptedPayload: msg.encryptedPayload,
        chainKey: msg.chainKey,
      );

      decrypted.add(
        DecryptedMessageDTO(
          id: msg.id,
          messageId: msg.messageId,
          fromPublicKey: msg.fromPublicKey,
          toPublicKey: msg.toPublicKey,
          plaintext: plaintext,
          createdAt: msg.createdAt,
        ),
      );
    } catch (e) {
      // Skip messages that fail decryption (corrupted/wrong key)
      continue;
    }
  }

  final processingTime = DateTime.now().difference(startTime);

  return DecryptionResult(
    decryptedMessages: decrypted,
    batchNumber: 1,
    totalBatches: 1,
    processingTime: processingTime,
  );
}

/// Decrypts a single message (placeholder)
Future<String> _decryptMessage({
  required String encryptedPayload,
  required String chainKey,
}) async {
  // In real implementation:
  // 1. Derive message key from chain key using KDF_CK
  // 2. Derive cipher key, mac key, IV using KDF_MK
  // 3. Decrypt with AES-256-GCM
  // 4. Return plaintext
  
  return "[Decrypted: $encryptedPayload]";
}

/// Error returned from isolate
class DecryptionError {
  final String error;

  DecryptionError({required this.error});
}

// ============================================================================
// LAZY-LOADING MESSAGE DAO
// ============================================================================

/// Data Access Object for lazy-loading messages with background decryption
class LazyMessageDAO {
  final Database database;
  final int batchSize;
  late Isolate _decryptionIsolate;
  late SendPort _decryptionSendPort;
  late ReceivePort _decryptionReceivePort;

  /// Current page being displayed
  int _currentPage = 0;

  /// Cache of already-decrypted messages
  final Map<int, DecryptedMessageDTO> _decryptedCache = {};

  /// Queue of pending decrypt requests
  final List<Future<DecryptionResult>> _pendingDecryptions = [];

  LazyMessageDAO({
    required this.database,
    this.batchSize = 20,
  });

  /// Initialize background isolate
  Future<void> initialize() async {
    _decryptionReceivePort = ReceivePort();
    _decryptionIsolate = await Isolate.spawn(
      _decryptionIsolateEntryPoint,
      _decryptionReceivePort.sendPort,
    );

    // Get send port from isolate
    _decryptionSendPort = await _decryptionReceivePort.first as SendPort;
  }

  /// Load next page of messages (efficiently)
  /// Queries DB for encrypted data, sends to background isolate
  /// Returns stream of decrypted messages as they become available
  Stream<DecryptedMessageDTO> loadNextPageStream({
    required String contactPublicKey,
  }) async* {
    // Query database for encrypted messages (20 at a time)
    final encryptedMessages = await _queryEncryptedMessages(
      contactPublicKey: contactPublicKey,
      offset: _currentPage * batchSize,
      limit: batchSize,
    );

    if (encryptedMessages.isEmpty) {
      return; // No more messages
    }

    // Send to background isolate for decryption
    final decryptionFuture = _decryptInBackground(encryptedMessages);

    // Yield results as they complete
    final result = await decryptionFuture;

    for (final decrypted in result.decryptedMessages) {
      // Cache in memory
      _decryptedCache[decrypted.id] = decrypted;

      // Yield to UI stream
      yield decrypted;

      // Small delay to prevent UI blocking
      // (Even though decryption is in background, yielding should be paced)
      await Future.delayed(Duration(milliseconds: 10));
    }

    _currentPage++;
  }

  /// Preload next page in background (user might scroll)
  Future<void> preloadNextPage({
    required String contactPublicKey,
  }) async {
    final nextPageMessages = await _queryEncryptedMessages(
      contactPublicKey: contactPublicKey,
      offset: (_currentPage + 1) * batchSize,
      limit: batchSize,
    );

    if (nextPageMessages.isNotEmpty) {
      // Queue for decryption but don't wait
      _decryptInBackground(nextPageMessages);
    }
  }

  /// Send batch to background isolate
  Future<DecryptionResult> _decryptInBackground(
      List<EncryptedMessageDTO> messages) {
    final completer = Completer<DecryptionResult>();

    // Create receive port for this specific decryption task
    final receivePort = ReceivePort();

    receivePort.listen((message) {
      if (message is DecryptionResult) {
        completer.complete(message);
      } else if (message is DecryptionError) {
        completer.completeError(Exception(message.error));
      }
      receivePort.close();
    });

    // Send task to isolate
    _decryptionSendPort.send(
      DecryptionTask(
        encryptedMessages: messages,
        signalRootKey: Uint8List(32), // Would come from database
        batchSize: batchSize,
      ),
    );

    return completer.future;
  }

  /// Query encrypted messages from database
  Future<List<EncryptedMessageDTO>> _queryEncryptedMessages({
    required String contactPublicKey,
    required int offset,
    required int limit,
  }) async {
    // Query the database for encrypted messages
    // In real implementation, would use Drift queries
    return [];
  }

  /// Get a cached decrypted message
  DecryptedMessageDTO? getCachedMessage(int messageId) {
    return _decryptedCache[messageId];
  }

  /// Clear cache (free memory on low-end devices)
  void clearCache() {
    _decryptedCache.clear();
  }

  /// Shutdown isolate gracefully
  Future<void> shutdown() async {
    _decryptionIsolate.kill();
    _decryptionReceivePort.close();
  }
}

// ============================================================================
// UI INTEGRATION: PAGINATED LIST WITH BACKGROUND LOADING
// ============================================================================

import 'package:flutter/material.dart';

/// Widget that displays messages with lazy-loading
class LazyMessageListView extends StatefulWidget {
  final LazyMessageDAO dao;
  final String contactPublicKey;

  const LazyMessageListView({
    Key? key,
    required this.dao,
    required this.contactPublicKey,
  }) : super(key: key);

  @override
  State<LazyMessageListView> createState() => _LazyMessageListViewState();
}

class _LazyMessageListViewState extends State<LazyMessageListView> {
  late ScrollController _scrollController;
  final List<DecryptedMessageDTO> _displayedMessages = [];
  bool _isLoadingMore = false;
  bool _hasMoreMessages = true;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    
    // Initial load
    _loadNextPage();
  }

  void _onScroll() {
    // Preload next page when user is 80% through current page
    if (_scrollController.position.pixels >
        _scrollController.position.maxScrollExtent * 0.8) {
      widget.dao.preloadNextPage(contactPublicKey: widget.contactPublicKey);
    }
  }

  void _loadNextPage() {
    if (_isLoadingMore || !_hasMoreMessages) {
      return;
    }

    setState(() => _isLoadingMore = true);

    // Load from stream
    widget.dao
        .loadNextPageStream(contactPublicKey: widget.contactPublicKey)
        .listen(
      (decryptedMessage) {
        setState(() {
          _displayedMessages.add(decryptedMessage);
        });
      },
      onError: (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Decryption error: $e')),
        );
      },
      onDone: () {
        setState(() => _isLoadingMore = false);
      },
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scrollController,
      itemCount: _displayedMessages.length + (_isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _displayedMessages.length) {
          // Loading indicator
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(),
              ),
            ),
          );
        }

        final message = _displayedMessages[index];
        return MessageTile(message: message);
      },
    );
  }
}

/// Individual message tile
class MessageTile extends StatelessWidget {
  final DecryptedMessageDTO message;

  const MessageTile({Key? key, required this.message}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(message.plaintext),
      subtitle: Text(
        'From: ${message.fromPublicKey.substring(0, 8)}...',
      ),
      trailing: Text(
        DateTime.fromMillisecondsSinceEpoch(message.createdAt ~/ 1000000)
            .toString(),
        style: const TextStyle(fontSize: 12),
      ),
    );
  }
}

// ============================================================================
// PERFORMANCE METRICS
// ============================================================================

/// Tracks decryption performance for i3 optimization
class DecryptionPerformanceTracker {
  final List<Duration> _processingTimes = [];
  final List<int> _messageCounts = [];

  void recordBatch(DecryptionResult result) {
    _processingTimes.add(result.processingTime);
    _messageCounts.add(result.decryptedMessages.length);
  }

  double getAverageMessagesPerSecond() {
    if (_processingTimes.isEmpty) return 0;

    double totalDuration = 0;
    int totalMessages = 0;

    for (int i = 0; i < _processingTimes.length; i++) {
      totalDuration += _processingTimes[i].inMilliseconds;
      totalMessages += _messageCounts[i];
    }

    if (totalDuration == 0) return 0;
    return (totalMessages / totalDuration) * 1000; // msgs/sec
  }

  Duration getAverageDecryptionTime() {
    if (_processingTimes.isEmpty) return Duration.zero;

    int totalMilliseconds = 0;
    for (final duration in _processingTimes) {
      totalMilliseconds += duration.inMilliseconds;
    }

    return Duration(milliseconds: totalMilliseconds ~/ _processingTimes.length);
  }

  void printStats() {
    print('⏱️ Decryption Performance (i3 Hardware):');
    print(
        '   Average: ${getAverageDecryptionTime().inMilliseconds}ms per batch');
    print('   Throughput: ${getAverageMessagesPerSecond().toStringAsFixed(1)} msgs/sec');
  }
}
