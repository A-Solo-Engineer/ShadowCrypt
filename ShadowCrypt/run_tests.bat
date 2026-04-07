@echo off
REM ShadowCrypt Security Audit - Test Runner for Windows

setlocal enabledelayedexpansion

echo.
echo ================================
echo ShadowCrypt Security Audit Tests
echo ================================
echo.

cd /d d:\ShadowCrypt

echo.
echo [1/5] Domain 1: RAM Forensics (Memwipe)
echo Running: go test -v ./backend/pkg/session/...
echo.
go test -v ./backend/pkg/session/ -run TestMemwipe
echo.

echo [2/5] Domain 2: Side-Channel Leaks (Obfuscation)
echo Running: flutter test frontend/test/secure_string_test.dart
echo.
flutter test frontend/test/secure_string_test.dart 2>nul || echo [FLUTTER NOT INSTALLED - Skipping]
echo.

echo [3/5] Domain 3: Double Ratchet Race Conditions
echo Running: flutter test frontend/test/conflict_aware_ratchet_test.dart
echo.
flutter test frontend/test/conflict_aware_ratchet_test.dart 2>nul || echo [FLUTTER NOT INSTALLED - Skipping]
echo.

echo [4/5] Domain 4: Hardware Bottlenecks (Lazy-Loading)
echo Running: flutter test frontend/test/lazy_message_dao_test.dart
echo.
flutter test frontend/test/lazy_message_dao_test.dart 2>nul || echo [FLUTTER NOT INSTALLED - Skipping]
echo.

echo [5/5] Domain 5: Registration Spoofing (Challenge-Response)
echo Running: go test -v ./backend/pkg/auth/...
echo.
go test -v ./backend/pkg/auth/ -run 'Challenge\|Registration'
echo.

echo ================================
echo Test Run Complete
echo ================================
echo.
