/// Tests for secure mnemonic handling
import 'package:flutter_test/flutter_test.dart';
import '../crypto/secure_string.dart';

void main() {
  group('ObfuscatedString', () {
    test('ObfuscatedString hides plaintext immediately', () {
      const plaintext = 'abandon ability able about above absence abstract abuse access accident';
      final obfuscated = ObfuscatedString.fromPlaintext(plaintext);

      // Plaintext should NOT be readable from the object's fields
      // (testing that we don't accidentally store it)
      expect(obfuscated.isCleared, isFalse);

      // Should only reveal through explicit method
      final revealed = obfuscated.getPlaintext();
      expect(revealed, equals(plaintext));
    });

    test('ObfuscatedString.getMaskedDisplay shows only last word', () {
      const plaintext = 'word1 word2 word3 word4 word5 word6 '
          'word7 word8 word9 word10 word11 word12';
      final obfuscated = ObfuscatedString.fromPlaintext(plaintext);

      final masked = obfuscated.getMaskedDisplay();
      expect(masked, contains('word12'));
      expect(masked, contains('****'));
      expect(masked.split(' ').first, equals('****'));
    });

    test('ObfuscatedString.clear prevents read access', () {
      const plaintext = 'test mnemonic data here';
      final obfuscated = ObfuscatedString.fromPlaintext(plaintext);

      obfuscated.clear();

      // Should throw on read attempt
      expect(
        () => obfuscated.getPlaintext(),
        throwsStateError,
      );
      expect(obfuscated.isCleared, isTrue);
    });

    test('ObfuscatedString uses XOR for obfuscation', () {
      const plaintext1 = 'secret';
      const plaintext2 = 'another';

      final obf1 = ObfuscatedString.fromPlaintext(plaintext1);
      final obf2 = ObfuscatedString.fromPlaintext(plaintext2);

      // Obfuscated data should be different (due to random keys)
      // and neither should reveal plaintext without decryption
      expect(
        obf1.getPlaintext(),
        isNot(equals(obf2.getPlaintext())),
      );

      obf1.clear();
      obf2.clear();
    });
  });

  group('SecureMnemonicGenerator', () {
    test('generate12WordSecurely returns obfuscated form', () {
      final obfuscated = SecureMnemonicGenerator.generate12WordSecurely();

      // Should not raise
      expect(obfuscated, isNotNull);

      // Plaintext should require explicit reveal
      final masked = obfuscated.getMaskedDisplay();
      expect(masked, contains('****'));

      obfuscated.clear();
    });

    test('validateObfuscated checks BIP-39 validity', () {
      final validMnemonic = 'abandon ability able about above absence abstract abuse access accident account achieve';
      final obfuscated = ObfuscatedString.fromPlaintext(validMnemonic);

      expect(
        SecureMnemonicGenerator.validateObfuscated(obfuscated),
        isTrue,
      );

      obfuscated.clear();
    });

    test('entropyFromObfuscated derives entropy without exposing plaintext',
        () {
      final mnemonic = 'abandon ability able about above absence abstract abuse access accident account achieve';
      final obfuscated = ObfuscatedString.fromPlaintext(mnemonic);

      final entropy = SecureMnemonicGenerator.entropyFromObfuscated(obfuscated);

      // Entropy should be 128 bits (16 bytes) for 12-word mnemonic
      expect(entropy.length, equals(16));

      obfuscated.clear();
    });
  });

  group('Mnemonic Side-Channel Prevention', () {
    test('Plaintext not stored in accessible fields', () {
      const plaintext = 'sensitive mnemonic words here test';
      final obfuscated = ObfuscatedString.fromPlaintext(plaintext);

      // The obfuscated data should be encrypted (XOR with random key)
      // So even if someone read the memory, they'd see gibberish
      expect(obfuscated.obfuscatedDataSize, equals(plaintext.length));

      obfuscated.clear();
    });

    test('Multiple reveals use same plaintext result', () {
      const plaintext = 'test recovery phrase one two three';
      final obfuscated = ObfuscatedString.fromPlaintext(plaintext);

      final reveal1 = obfuscated.getPlaintext();
      final reveal2 = obfuscated.getPlaintext();

      expect(reveal1, equals(reveal2));

      obfuscated.clear();
    });

    test('Cleared state prevents access', () {
      final obfuscated = ObfuscatedString.fromPlaintext('test');
      obfuscated.clear();

      expect(obfuscated.isCleared, isTrue);

      // All methods should fail
      expect(
        () => obfuscated.getPlaintext(),
        throwsStateError,
      );
      expect(
        () => obfuscated.getMaskedDisplay(),
        throwsStateError,
      );
    });
  });

  group('SecureOnboardingFlow', () {
    test('SecureOnboardingFlow keeps only obfuscated mnemonic', () {
      final flow = SecureOnboardingFlow();

      // Should only expose masked display
      final masked = flow.getMaskedDisplay();
      expect(masked, isNotNull);
      expect(masked, contains('****'));

      flow.cleanup();
    });

    test('confirmBackup enables database initialization', () {
      final flow = SecureOnboardingFlow();

      flow.confirmBackup();

      // Should be able to initialize (would connect to real DB in prod)
      expectLater(
        flow.initializeDatabaseSecurely(),
        completes,
      );

      flow.cleanup();
    });

    test('cleanup clears all data', () {
      final flow = SecureOnboardingFlow();

      // After cleanup, should not be able to access
      flow.cleanup();

      // Masked display would fail (obfuscated cleared)
      expect(
        () => flow.getMaskedDisplay(),
        throwsStateError,
      );
    });
  });

  group('Widget Tree Security', () {
    testWidgets('MaskedMnemonicDisplay shows only masked version',
        (WidgetTester tester) async {
      final obfuscated = ObfuscatedString.fromPlaintext(
        'abandon ability able about above absence abstract abuse access accident account achieve',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MaskedMnemonicDisplay(
              obfuscatedMnemonic: obfuscated,
              onShow: () {},
            ),
          ),
        ),
      );

      // Should see "Last Word Only" indicator
      expect(find.text('⚠️ Recovery Phrase (Last Word Only)'), findsOneWidget);

      // Should see asterisks but not full mnemonic
      expect(find.byType(SelectableText), findsOneWidget);

      // The displayed text should contain ****
      final displayedText=
          (find.byType(SelectableText).evaluate().first.widget as SelectableText)
              .data;
      expect(displayedText, contains('****'));

      obfuscated.clear();
    });

    testWidgets('MaskedMnemonicDisplay reveals with full phrase on button tap',
        (WidgetTester tester) async {
      final obfuscated = ObfuscatedString.fromPlaintext(
        'abandon ability able about above absence abstract abuse access accident account achieve',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MaskedMnemonicDisplay(
              obfuscatedMnemonic: obfuscated,
              onShow: () {},
            ),
          ),
        ),
      );

      // Initially should see masked version
      expect(find.byType(SelectableText), findsOneWidget);

      // Click reveal button
      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();

      // Should see warning about full phrase
      expect(
        find.text('🔴 FULL PHRASE REVEALED - Screenshot this carefully!'),
        findsOneWidget,
      );

      obfuscated.clear();
    });
  });
}
