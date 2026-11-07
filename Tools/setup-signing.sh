#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Explicit local setup only; build.sh never changes a keychain.
set -euo pipefail
identity='Hutchbar Local Signing'
keychain="$HOME/Library/Keychains/login.keychain-db"
if security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
  echo 'Existing certificate retained. Unlock the login keychain if codesign needs access.'
  printf 'export HUTCHBAR_SIGN_IDENTITY=%q\n' "$identity"
  exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
cat > "$work/openssl.cnf" <<CONFIG
[req]
distinguished_name = dn
x509_extensions = code_signing
prompt = no
[dn]
CN = $identity
[code_signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -config "$work/openssl.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem"
p12_password=$(openssl rand -hex 24)
export HUTCHBAR_P12_PASSWORD="$p12_password"
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$identity" \
  -out "$work/identity.p12" -passout env:HUTCHBAR_P12_PASSWORD \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$work/identity.p12" -k "$keychain" -P "$p12_password" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"
echo 'Local identity installed in the login keychain. This is not a Developer ID identity.'
printf 'export HUTCHBAR_SIGN_IDENTITY=%q\n' "$identity"
