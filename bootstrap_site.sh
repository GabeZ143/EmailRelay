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

mkdir -p "$SECRETS" "$CERTS_DIR" 

# 1) Create outbound M365 secret map (idempotent: create once)
SASL_FILE="$SECRETS/sasl_passwd"
if [ -f "$SASL_FILE" ]; then
  echo ">> $SASL_FILE exists; leaving as-is"
else
  echo ">> Writing $SASL_FILE"
  cat > "$SASL_FILE" <<EOF
[smtp.office365.com]:587 ${M365_USER}:${M365_PASS}
EOF
fi

# 2) Ensure virtual map exists (edit later as needed)
if [ ! -f "$SECRETS/virtual" ]; then
  echo ">> Creating example virtual map"
  cat > "$SECRETS/virtual" <<'EOF'
alerts@infraspec.io user1@example.com, user2@example.com
EOF
fi

# 3) Inbound SASL user (toolbox container writes to host file)
if [ -n "${INBOUND_USER:-}" ] && [ -n "${INBOUND_PASS:-}" ] && [ -n "${INBOUND_REALM:-}" ]; then
  echo ">> Creating/updating ${INBOUND_USER}@${INBOUND_REALM} in sasldb2"
  # feed password twice via stdin (-p)
  printf "%s\n%s\n" "$INBOUND_PASS" "$INBOUND_PASS" | sudo docker run --rm -i \
    -e INBOUND_REALM="$INBOUND_REALM" \
    -e INBOUND_USER="$INBOUND_USER" \
    -v "$(pwd)/secrets:/secrets" \
    ghcr.io/gabez143/postfix-relay:latest \
    sh -lc 'saslpasswd2 -c -p -f /secrets/sasldb2 -u "$INBOUND_REALM" "$INBOUND_USER"'
else
  echo ">> Skipping sasldb2 (INBOUND_* not fully set)"
fi

# 4) Self-signed certificate (idempotent)
if [ ! -f "$CERTS_DIR/server.crt" ] || [ ! -f "$CERTS_DIR/server.key" ]; then
  echo ">> Generating self-signed cert for $MYHOSTNAME (${SELF_SIGNED_DAYS:-30} days)"
  openssl req -x509 -newkey rsa:2048 -sha256 -days "${SELF_SIGNED_DAYS:-30}" -nodes \
    -keyout "$CERTS_DIR/server.key" \
    -out    "$CERTS_DIR/server.crt" \
    -subj "/CN=$MYHOSTNAME" \
    -addext "subjectAltName=DNS:$MYHOSTNAME"
else
  echo ">> Using existing cert/key at $CERTS_DIR"
fi

cat <<INFO

✅ Bootstrap finished.

Next:
1) Ensure compose mounts include:
   - ./secrets/sasldb2 -> /etc/sasldb2:ro
   - ./secrets/sasl_passwd -> /run/secrets/sasl_passwd:ro
   - ./secrets/virtual -> /etc/postfix/virtual:ro
   - ./secrets/certs -> /etc/ssl/postfix:ro

2) Start (or redeploy) Postfix:
   docker compose up -d

3) Reload Postfix after any cert/virtual changes:
   docker exec postfix-relay postfix reload

INFO
