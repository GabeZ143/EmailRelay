#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-./site.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE"; exit 1; }

# Load env
set -o allexport
# shellcheck disable=SC1090
source "$ENV_FILE"
set +o allexport

SECRETS="./secrets"
CERTS_DIR="$SECRETS/certs"
LE_DIR="${LE_ROOT:-/opt/letsencrypt}"

mkdir -p "$SECRETS" "$CERTS_DIR" "$LE_DIR"

# 1) Create outbound M365 secret map
SASL_FILE="./secrets/sasl_passwd"
if [ -f "$SASL_FILE" ]; then
  echo ">> $SASL_FILE exists; leaving as-is"
else
  echo ">> Writing $SASL_FILE"
  umask 177
  cat > "$SASL_FILE" <<EOF
[smtp.office365.com]:587 ${M365_USER}:${M365_PASS}
EOF
  chmod 600 "$SASL_FILE"
fi

# 2) Ensure virtual map exists (edit later as needed)
[ -f "$SECRETS/virtual" ] || {
  echo ">> Creating example virtual map"
  cat > "$SECRETS/virtual" <<'EOF'
alerts@infraspec.io user1@example.com, user2@example.com
EOF
}

# 3) Inbound SASL user (toolbox container writes to host file)
if [ -n "${INBOUND_USER:-}" ] && [ -n "${INBOUND_PASS:-}" ] && [ -n "${INBOUND_REALM:-}" ]; then
  echo ">> Creating/updating ${INBOUND_USER}@${INBOUND_REALM} in sasldb2"
  printf "%s\n%s\n" "$INBOUND_PASS" "$INBOUND_PASS" | sudo docker run --rm -i \
    -v "$(pwd)/secrets:/secrets" \
    ghcr.io/gabez143/postfix-relay:latest \
    sh -lc 'saslpasswd2 -c -p -f /secrets/sasldb2 -u "$INBOUND_REALM" "$INBOUND_USER" && chmod 600 /secrets/sasldb2'
else
  echo ">> Skipping sasldb2 (INBOUND_* not fully set)"
fi

# 4) Certificate provisioning
if [ ! -f "$CERT_DIR/server.crt" ] || [ ! -f "$CERT_DIR/server.key" ]; then
  echo ">> Generating self-signed cert for $MYHOSTNAME ($SELF_SIGNED_DAYS days)"
  openssl req -x509 -newkey rsa:2048 -sha256 -days "${SELF_SIGNED_DAYS:-30}" -nodes \
    -keyout "$CERT_DIR/server.key" \
    -out    "$CERT_DIR/server.crt" \
    -subj "/CN=$MYHOSTNAME" \
    -addext "subjectAltName=DNS:$MYHOSTNAME"
  chmod 600 "$CERT_DIR/server.key"
else
  echo ">> Using existing cert/key at $CERT_DIR"
fi


cat <<INFO

✅ Bootstrap finished.

Next:
1) Ensure compose mounts include:
   - ./secrets/sasldb2 -> /etc/sasldb2:ro
   - ./secrets/sasl_passwd -> /run/secrets/sasl_passwd:ro
   - ./secrets/virtual -> /etc/postfix/virtual:ro
   - ./secrets/certs -> /etc/ssl/postfix:ro
   - ${LE_DIR} -> /opt/letsencrypt:ro  (if using Let's Encrypt)

2) Start (or redeploy) Postfix:
   docker compose up -d

3) If you used Let's Encrypt, set these into Postfix at runtime:
   (They are already picked up by entrypoint if you put them in site.env)
   TLS_CERT_FILE=${TLS_CERT_FILE}
   TLS_KEY_FILE=${TLS_KEY_FILE}

   You can add these lines to site.env so they persist:
   TLS_CERT_FILE=${TLS_CERT_FILE}
   TLS_KEY_FILE=${TLS_KEY_FILE}

4) Reload Postfix after cert changes:
   docker exec postfix-relay postfix reload

INFO
