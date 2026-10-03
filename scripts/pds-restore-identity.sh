#!/usr/bin/env bash
# Decrypt an identity archive written by the host's pds-backup-identity (format v2).
#
#   scripts/pds-restore-identity.sh <identity-STAMP.enc.tar> <backup-private-key.pem> <out-dir>
#
# Writes <out-dir>/secrets.env: the PDS's JWT secret, admin password and PLC rotation key. Put it
# on a data volume at /pds/secrets.env to bring the identity back on a new host. The HMAC is
# checked before anything is decrypted, so a tampered or truncated archive is refused.
# Needs OpenSSL 3 (macOS's LibreSSL lacks the OAEP-SHA-256 options; use Homebrew's openssl@3).
set -euo pipefail

[ $# -eq 3 ] || { echo "usage: $0 <archive.enc.tar> <private-key.pem> <out-dir>" >&2; exit 2; }
ARCHIVE=$1 KEY=$2 OUT=$3
OPENSSL=${OPENSSL:-openssl}

umask 077
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
tar -xf "$ARCHIVE" -C "$WORK"
grep -q '^pds-identity-backup v2:' "$WORK/FORMAT" 2>/dev/null \
  || { echo "refusing: $ARCHIVE is not a v2 identity archive" >&2; exit 1; }

"$OPENSSL" pkeyutl -decrypt -inkey "$KEY" \
  -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -pkeyopt rsa_mgf1_md:sha256 \
  -in "$WORK/keys.enc" -out "$WORK/keys"
[ "$(wc -c < "$WORK/keys")" -eq 64 ] || { echo "refusing: unwrapped key material is not 64 bytes" >&2; exit 1; }
ENC_KEY=$(head -c 32 "$WORK/keys" | xxd -p -c 64)
MAC_KEY=$(tail -c 32 "$WORK/keys" | xxd -p -c 64)

EXPECTED=$(cat "$WORK/iv" "$WORK/payload.enc" \
  | "$OPENSSL" dgst -sha256 -mac HMAC -macopt "hexkey:$MAC_KEY" -binary | xxd -p -c 64)
ACTUAL=$(xxd -p -c 64 < "$WORK/payload.mac")
[ "$EXPECTED" = "$ACTUAL" ] || { echo "refusing: HMAC mismatch -- the archive was altered or truncated" >&2; exit 1; }

"$OPENSSL" enc -d -aes-256-cbc -K "$ENC_KEY" -iv "$(cat "$WORK/iv")" \
  -in "$WORK/payload.enc" -out "$WORK/identity.tar.gz"
mkdir -p "$OUT"
tar -xzf "$WORK/identity.tar.gz" -C "$OUT" secrets.env
echo "restored $OUT/secrets.env"
