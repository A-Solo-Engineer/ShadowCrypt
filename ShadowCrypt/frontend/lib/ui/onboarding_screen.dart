/// Vault initialization and onboarding for new users
library onboarding;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/shadow_brand_header.dart';
import 'crypto/key_management.dart';
import 'data/database/vault_database.dart';

/// First-time setup: Generate mnemonic and initialize vault
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({Key? key}) : super(key: key);

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late String _generatedMnemonic;
  bool _mnemonicConfirmed = false;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _generatedMnemonic = MnemonicGenerator.generate12WordMnemonic();
  }

  Future<void> _initializeVaultWithMnemonic() async {
    setState(() => _isProcessing = true);

    try {
      // Initialize encrypted database with mnemonic
      const dbPath = "/data/local/shadowcrypt.db";
      
      await VaultDatabase.initialize(
        mnemonic: _generatedMnemonic,
        dbPath: dbPath,
      );

      // Generate identity keypair from mnemonic
      final identityKeypair = await KeyDerivation.deriveIdentityKeypair(
        mnemonic: _generatedMnemonic,
      );

      // Derive encryption key
      final encryptionKey = await KeyDerivation.deriveEncryptionKey(
        mnemonic: _generatedMnemonic,
      );

      if (!mounted) return;

      // Navigate to main app
      Navigator.of(context).pushReplacementNamed('/home');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const ShadowBrandHeader(),
        centerTitle: true,
        backgroundColor: Colors.black,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            const Text(
              'Your Recovery Phrase',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Save this 12-word phrase in a secure location. '
              'It\'s the only way to recover your vault if you lose access.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            
            // Mnemonic display
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(8),
                color: Colors.black12,
              ),
              child: MnemonicDisplay(mnemonic: _generatedMnemonic),
            ),
            
            const SizedBox(height: 24),
            
            // Copy button
            ElevatedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _generatedMnemonic));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy to Clipboard'),
            ),
            
            const SizedBox(height: 32),
            
            // Confirmation checkbox
            Row(
              children: [
                Checkbox(
                  value: _mnemonicConfirmed,
                  onChanged: (value) {
                    setState(() => _mnemonicConfirmed = value ?? false);
                  },
                ),
                const Expanded(
                  child: Text(
                    'I have safely backed up my recovery phrase',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 24),
            
            // Initialize button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (_mnemonicConfirmed && !_isProcessing)
                    ? _initializeVaultWithMnemonic
                    : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.green,
                ),
                child: Text(
                  _isProcessing ? 'Initializing...' : 'Initialize Vault',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Displays mnemonic words in a grid
class MnemonicDisplay extends StatelessWidget {
  final String mnemonic;

  const MnemonicDisplay({Key? key, required this.mnemonic}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final words = mnemonic.split(' ');
    
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 2.5,
      ),
      itemCount: words.length,
      itemBuilder: (context, index) {
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.blue),
            borderRadius: BorderRadius.circular(4),
            color: Colors.blue.withAlpha(20),
          ),
          child: Center(
            child: Text(
              '${index + 1}. ${words[index]}',
              style: const TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }
}
