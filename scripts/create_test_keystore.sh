#!/usr/bin/env bash
set -euo pipefail

# Script to generate a local dry-run self-signed upload keystore for testing release APK builds.
# NEVER commit keystore or key.properties files to source control!

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYSTORE_PATH="${PROJECT_ROOT}/android/oneshare-test-upload.jks"
KEY_PROPERTIES_PATH="${PROJECT_ROOT}/android/key.properties"

KEYTOOL_BIN="keytool"
if ! command -v keytool >/dev/null 2>&1 || ! keytool -help >/dev/null 2>&1; then
  if [ -x "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" ]; then
    KEYTOOL_BIN="/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool"
  fi
fi

echo "==> Generating local test keystore at ${KEYSTORE_PATH}..."

"${KEYTOOL_BIN}" -genkeypair \
  -v \
  -keystore "${KEYSTORE_PATH}" \
  -alias oneshare-test \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -storepass onesharetestpass \
  -keypass onesharetestpass \
  -dname "CN=OneShare Test, OU=Dev, O=OneShare, L=Local, ST=Local, C=US"

echo "==> Generating android/key.properties..."
cat <<EOF > "${KEY_PROPERTIES_PATH}"
storePassword=onesharetestpass
keyPassword=onesharetestpass
keyAlias=oneshare-test
storeFile=oneshare-test-upload.jks
EOF

echo "==> Done! Local dry-run keystore generated."
echo "    Keystore: ${KEYSTORE_PATH}"
echo "    Properties: ${KEY_PROPERTIES_PATH}"
