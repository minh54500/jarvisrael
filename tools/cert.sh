#!/bin/zsh
# Crée une fois le certificat local « Encoche Dev » qui signe Encoche à chaque build.
# Même signature d'un build à l'autre = macOS garde les autorisations (Accessibilité, Spotify).
# Il ne sert qu'à signer du code, sur ce Mac. Pour l'enlever : Trousseaux d'accès → « Encoche Dev » → Supprimer.
set -euo pipefail
NAME="Encoche Dev"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "✓ « $NAME » existe déjà."; exit 0; fi

TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT
cat > $TMP/cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
# L'OpenSSL d'Apple : celui de Homebrew (OpenSSL 3) chiffre le .p12 d'une façon que `security` ne sait pas lire.
OSSL=/usr/bin/openssl
LEGACY=(); $OSSL version | grep -q '^OpenSSL 3' && LEGACY=(-legacy)
$OSSL req -x509 -newkey rsa:2048 -nodes -keyout $TMP/key.pem -out $TMP/cert.pem -days 3650 -config $TMP/cert.cnf 2>/dev/null
$OSSL pkcs12 -export $LEGACY -inkey $TMP/key.pem -in $TMP/cert.pem -out $TMP/cert.p12 -passout pass:encoche -name "$NAME"
security import $TMP/cert.p12 -k ~/Library/Keychains/login.keychain-db -P encoche -T /usr/bin/codesign >/dev/null

# Les autorisations données à l'ancienne signature (ad hoc) ne valent plus : on repart propre.
tccutil reset Accessibility io.github.minh54500.encoche >/dev/null 2>&1 || true
tccutil reset AppleEvents io.github.minh54500.encoche >/dev/null 2>&1 || true
echo "✓ Certificat « $NAME » créé. Relance ./build.sh, autorise Encoche une dernière fois, et c'est bon."
