# ShadowCrypt Flutter Frontend Build & Testing Guide

## Prerequisites

- Flutter 3.10.0+
- Dart 3.0.0+
- Android Studio or VS Code with Flutter extension
- Windows build tools (for Windows i3 laptop target)
- Xcode (if targeting macOS)

## Setup

### 1. Install Dependencies

```bash
cd frontend

# Fetch pub packages
flutter pub get

# Generate Drift ORM code
flutter pub run build_runner build

# Or watch for changes
flutter pub run build_runner watch
```

### 2. Project Structure

```
frontend/
├── lib/
│   ├── main.dart                    # App entry point & vault unlock
│   ├── data/
│   │   ├── database/
│   │   │   ├── schema.dart          # Drift table definitions
│   │   │   └── vault_database.dart  # Database initialization + queries
│   │   └── models/
│   ├── crypto/
│   │   ├── key_management.dart      # Mnemonic, AES-256, PBKDF2
│   │   └── signal_protocol.dart     # Double Ratchet implementation
│   ├── core/
│   └── ui/
│       └── onboarding_screen.dart  # Vault creation flow
├── pubspec.yaml                     # Dependencies
└── test/
    └── crypto_test.dart            # Unit tests
```

## Development

### Run on Windows Desktop

```bash
# Enable Windows desktop support
flutter config --enable-windows-desktop

# Run app
flutter run -d windows

# Build optimized binary
flutter build windows --release
```

### Run on Android Emulator

```bash
# List available devices
flutter devices

# Run on emulator
flutter run
```

## Testing

### Unit Tests: Cryptography

```bash
# Run all tests
flutter test

# Run specific test
flutter test test/crypto_test.dart --verbose

# Test coverage
flutter test --coverage
lcov --list coverage/lcov.info
```

### Integration Test: Vault Unlock

Create `test_integration.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shadowcrypt/main.dart';
import 'package:shadowcrypt/crypto/key_management.dart';
import 'package:shadowcrypt/data/database/vault_database.dart';

void main() {
  group('Vault Unlock Flow', () {
    test('BIP-39 mnemonic generation', () {
      final mnemonic = MnemonicGenerator.generate12WordMnemonic();
      expect(mnemonic.split(' ').length, equals(12));
      expect(MnemonicGenerator.isValidMnemonic(mnemonic), isTrue);
    });

    test('Invalid mnemonic rejected', () {
      const invalid = 'invalid fake mnemonic words here';
      expect(MnemonicGenerator.isValidMnemonic(invalid), isFalse);
    });

    test('Key derivation from mnemonic', () async {
      final mnemonic = 
          'abandon ability able about above absence abstract abuse access accident';
      final key = await KeyDerivation.deriveEncryptionKey(
        mnemonic: mnemonic,
      );
      expect(key.length, equals(32)); // 256 bits
    });

    test('Database initialization', () async {
      final mnemonic = MnemonicGenerator.generate12WordMnemonic();
      
      // Should not throw
      await VaultDatabase.initialize(
        mnemonic: mnemonic,
        dbPath: ':memory:', // In-memory SQLite for testing
      );
      
      expect(VaultDatabase.instance, isNotNull);
    });
  });
}
```

Run:
```bash
flutter test test_integration.dart
```

## Building for i3 Laptop (Windows)

### Performance Optimization

The i3 processor has limited resources:
- **RAM**: Typically 4GB
- **Storage**: SSD ~128GB
- **CPU**: Dual-core with hyperthreading

**Optimizations:**

1. **Delta-Sync for Message Decryption**
   - Load 20 messages at a time
   - Lazy-load older messages on scroll
   - Prevents CPU spike on large conversations

2. **Database Indexing**
   - Add indices on `from_public_key`, `to_public_key`, `created_at`
   - Drift automatically generates optimized queries

3. **Build Configuration**
   ```yaml
   # flutter.yaml
   target-platform: windows
   
   dart-obfuscation: true
   split-debug-info: build/
   ```

4. **Release Build**
   ```bash
   flutter build windows --release
   # Output: build\windows\runner\Release\shadowcrypt.exe
   # Size: ~150MB (includes Flutter engine)
   ```

### Install on Windows i3 Laptop

```bash
# Build APK/executable
flutter build windows --release

# Or create installer using NSIS
# (Third-party tool, optional)

# Direct installation
cp build/windows/runner/Release/shadowcrypt.exe C:\Users\Username\Desktop\
```

## Running Tests for Key Derivation

### Test 1: BIP-39 Entropy

```dart
test('BIP-39 entropy conversion', () {
  const mnemonic = 'abandon ability able about above absence abstract abuse access accident';
  final entropy = MnemonicGenerator.mnemonicToEntropy(mnemonic);
  
  expect(entropy.length, equals(16)); // 128 bits = 16 bytes
  
  // Convert back
  final recovered = MnemonicGenerator.entropyToMnemonic(entropy);
  expect(recovered, equals(mnemonic));
});
```

### Test 2: PBKDF2-SHA256 Key Derivation

```dart
test('PBKDF2-SHA256 produces correct key length', () async {
  final mnemonic = MnemonicGenerator.generate12WordMnemonic();
  
  final key = await KeyDerivation.deriveEncryptionKey(
    mnemonic: mnemonic,
    salt: 'test_salt',
    iterations: 10000, // Fast for testing
    length: 32,
  );
  
  expect(key.length, equals(32));
});
```

### Test 3: SQLCipher Encryption

```dart
test('Database encryption with derived key', () async {
  final mnemonic = MnemonicGenerator.generate12WordMnemonic();
  
  await VaultDatabase.initialize(
    mnemonic: mnemonic,
    dbPath: ':memory:',
  );
  
  // Try to query - if decryption fails, exception thrown
  final identity = await VaultDatabase.instance?.getActiveIdentity();
  
  // Can safely query or insert
  expect(identity, isNull); // No identity yet
});
```

## Debugging Tips

### Enable Debug Logging

```dart
// In lib/main.dart
import 'package:logger/logger.dart';

final logger = Logger();

void main() {
  logger.d('Starting ShadowCrypt...');
  runApp(const ShadowCryptApp());
}
```

### Inspect SQLCipher Database

```bash
# Install sqlite3-cipher tools (if available)
# export SQLCIPHER_PASSWORD='your_derived_key_hex'
# sqlcipher /path/to/db

# Or use Dart to query
dart run -S lib/debug_database.dart
```

### Performance Profiling

```bash
# Build with profiling enabled
flutter run -d windows --profile

# Open DevTools
flutter pub global run devtools

# Connect to running app and inspect:
# - CPU usage
# - Memory usage (particularly Dart heap)
# - Frame rate
```

## CI/CD Pipeline Setup (GitHub Actions)

Create `.github/workflows/flutter_test.yml`:

```yaml
name: Flutter Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.10.0'
      
      - name: Install dependencies
        run: flutter pub get
      
      - name: Generate code
        run: flutter pub run build_runner build
      
      - name: Run tests
        run: flutter test
      
      - name: Build release
        run: flutter build windows --release
      
      - name: Upload artifact
        uses: actions/upload-artifact@v3
        with:
          name: shadowcrypt-release
          path: build/windows/runner/Release/
```

## Known Issues & Workarounds

### Issue: Drift Code Generation Fails

```
Error: Could not find lib/data/database/vault_database.g.dart
```

**Fix:**
```bash
flutter clean
flutter pub get
flutter pub run build_runner build --delete-conflicting-outputs
```

### Issue: SQLCipher Key Too Long

```
Error: PRAGMA key: key material must be 32 bytes
```

**Fix:**
Ensure `deriveEncryptionKey()` output is exactly 32 bytes (256 bits):
```dart
final key = await KeyDerivation.deriveEncryptionKey(
  mnemonic: mnemonic,
  length: 32,  // Explicitly set
);
assert(key.length == 32);
```

## Deployment

### Windows Standalone Executable

```bash
# Build release
flutter build windows --release

# Output location
build/windows/runner/Release/shadowcrypt.exe

# Create self-extracting archive for distribution
# (Use 7-Zip or WinRAR)
```

### Android APK (if supporting Android)

```bash
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

---

**Last Updated**: April 2026
