#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# One-time, explicit setup of the self-signed release certificate. Touches no keychain.
# It writes a PKCS#12 file and its password to a new private directory and prints the
# commands that store them as `release` environment secrets. Nothing is uploaded here.
set -euo pipefail
identity='Hutchbar Release Signing'
out=${1:?Usage: Tools/make-release-cert.sh <new-directory-outside-the-repository>}
repo=$(cd "$(dirname "$0")/.." && pwd -P)
[[ ! -e "$out" ]] || { echo 'The directory must not exist yet.' >&2; exit 1; }
parent=$(dirname "$out")
[[ -d "$parent" ]] || { echo 'The parent directory must exist.' >&2; exit 1; }
out="$(cd "$parent" && pwd -P)/$(basename "$out")"
case "$out/" in "$repo"/*) echo 'Choose a directory outside the repository.' >&2; exit 1 ;; esac
mkdir -m 700 "$out"
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
  -keyout "$work/key.pem" -out "$out/certificate.pem" 2>/dev/null
password=$(openssl rand -hex 24)
printf '%s' "$password" > "$out/password.txt"
export HUTCHBAR_P12_PASSWORD="$password"
# Legacy PBE settings: macOS `security import` cannot read OpenSSL 3's default encryption.
openssl pkcs12 -export -inkey "$work/key.pem" -in "$out/certificate.pem" -name "$identity" \
  -out "$out/identity.p12" -passout env:HUTCHBAR_P12_PASSWORD \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
fingerprint=$(openssl x509 -in "$out/certificate.pem" -noout -fingerprint -sha256 \
  | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')
cat <<DONE
Created in $out (keep it private, back it up in a password manager, never commit it):
  identity.p12, password.txt, certificate.pem
Certificate SHA-256: $fingerprint
Valid for 10 years. If the key is lost, make a new certificate; users re-approve permissions once.

Store the secrets (the values are not printed):
  tr -d '\n' < <(base64 -i "$out/identity.p12") | gh secret set SIGNING_CERT_P12 --env release -R Code-oclock/hutchbar
  gh secret set SIGNING_CERT_PASSWORD --env release -R Code-oclock/hutchbar < "$out/password.txt"
  printf '%s' '$identity' | gh secret set SIGNING_IDENTITY --env release -R Code-oclock/hutchbar
DONE
