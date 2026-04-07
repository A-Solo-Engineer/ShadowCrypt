/// Main application entry point for ShadowCrypt
library shadowcrypt;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'data/database/vault_database.dart';
import 'crypto/key_management.dart';
import 'ui/onboarding_screen.dart';
import 'widgets/shadow_brand_header.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Database initialization deferred to auth flow
  runApp(const ShadowCryptApp());
}

class ShadowCryptApp extends StatelessWidget {
  const ShadowCryptApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShadowCrypt',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.grey,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
      ),
      home: const SplashScreen(),
      routes: {
        '/unlock': (context) => const VaultUnlockScreen(),
        '/onboarding': (context) => const OnboardingScreen(),
        '/home': (context) => const VaultUnlockScreen(),
      },
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => const VaultUnlockScreen(),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: ShadowBrandSplash(),
      ),
    );
  }
}

class ShadowBrandSplash extends StatelessWidget {
  const ShadowBrandSplash({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/logo/double_ratchet_logo_no_text.svg',
      width: 150,
      colorFilter: const ColorFilter.mode(
        Colors.white,
        BlendMode.srcIn,
      ),
    );
  }
}

/// Entry point: Vault unlock using BIP-39 mnemonic
class VaultUnlockScreen extends StatefulWidget {
  const VaultUnlockScreen({Key? key}) : super(key: key);

  @override
  State<VaultUnlockScreen> createState() => _VaultUnlockScreenState();
}

class _VaultUnlockScreenState extends State<VaultUnlockScreen> {
  final TextEditingController _mnemonicController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _mnemonicController.dispose();
    super.dispose();
  }

  Future<void> _unlockVault() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final mnemonic = _mnemonicController.text.trim();

      // Validate mnemonic
      if (!MnemonicGenerator.isValidMnemonic(mnemonic)) {
        throw Exception("Invalid BIP-39 mnemonic. Please verify your recovery phrase.");
      }

      // Initialize encrypted database
      // Database path would be device-specific (use path_provider in production)
      const dbPath = "/data/local/shadowcrypt.db";
      
      await VaultDatabase.initialize(
        mnemonic: mnemonic,
        dbPath: dbPath,
      );

      if (!mounted) return;

      // Navigate to main app
      Navigator.of(context).pushReplacementNamed('/home');
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
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
          children: [
            const SizedBox(height: 40),
            const Text(
              'Welcome back to ShadowCrypt',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const Text(
              'Enter your 12-word recovery phrase to unlock your encrypted vault.\n'
              'Your data is stored locally and encrypted with AES-256.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 40),
            
            // Mnemonic input
            TextField(
              controller: _mnemonicController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Enter 12-word recovery phrase',
                hintText: 'word1 word2 word3 ... word12',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                errorText: _error,
                errorMaxLines: 3,
              ),
            ),
            
            const SizedBox(height: 32),
            
            // Unlock button
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _unlockVault,
              icon: _isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.lock_open),
              label: Text(_isLoading ? 'Unlocking...' : 'Unlock Vault'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                backgroundColor: Colors.blue,
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Create new vault option
            TextButton(
              onPressed: () => Navigator.pushNamed(context, '/onboarding'),
              child: const Text('Create New Vault'),
            ),
          ],
        ),
      ),
    );
  }
}
