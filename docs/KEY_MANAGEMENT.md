# Key Management Guide

This document outlines key custody, release signing procedures, and security policies for OneShare.

## 1. Zero-Leakage Policy
- **Never commit keys**: No private signing keys, keystores (`*.jks`, `*.keystore`), or `key.properties` files may ever be committed to git.
- The `.gitignore` file enforces exclusion of:
  - `*.keystore`
  - `*.jks`
  - `key.properties`
  - `android/key.properties`

## 2. Generating the Official Production Upload Key
When preparing for Google Play Console submission (Phase 8b), generate an official upload key using Java `keytool`:

```bash
keytool -genkeypair -v \
  -keystore ~/oneshare-upload-key.jks \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -alias oneshare-upload \
  -storetype JKS
```

### Prompt Fields:
- What is your first and last name? -> OneShare Core Team
- What is the name of your organizational unit? -> Release Engineering
- What is the name of your organization? -> OneShare
- City, State, Country Code -> As appropriate

## 3. Configuring `key.properties` for CI / Local Release Builds
In `android/key.properties` (never committed to git):
```properties
storePassword=<STRONG_STORE_PASSWORD>
keyPassword=<STRONG_KEY_PASSWORD>
keyAlias=oneshare-upload
storeFile=/path/to/oneshare-upload-key.jks
```

## 4. Local Dry-Run Testing
To test release compilation locally without creating production credentials:
```bash
./scripts/create_test_keystore.sh
flutter build apk --release --dart-define=ENV=production
```
After testing, clean up temporary dry-run artifacts:
```bash
rm -f android/oneshare-test-upload.jks android/key.properties
```

## 5. Key Backup and Custody
1. Store the production upload keystore in a secure password manager or encrypted cloud vault (e.g. 1Password, Bitwarden, or hardware security module).
2. Maintain an offline backup on an encrypted USB drive stored in a secure physical location.
3. If the upload key is ever lost, contact Google Play Developer Support to reset the upload key via Play App Signing.
