#!/usr/bin/env bash
set -euo pipefail

ETCD_NODE="${ETCD_NODE:-http://etcd1:2379}"
SERVICE_PREFIX="/services/backend"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
TMP_CFG="/etc/haproxy/haproxy.cfg.tmp"
HAPROXY_PID="/run/haproxy.pid"

echo "Starting Load Balancer Node: ${HOSTNAME}"

mkdir -p /etc/haproxy /run

# --------------------------------------------------
# Helpers
# --------------------------------------------------
b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

# --------------------------------------------------
# Wait for etcd
# --------------------------------------------------
echo "Waiting for etcd at ${ETCD_NODE} ..."
until curl -sf "${ETCD_NODE}/health" >/dev/null; do
  sleep 1
done
echo "etcd is ready!"

# --------------------------------------------------
# Render HAProxy config (PURE, ATOMIC)
# --------------------------------------------------
render_config() {
  echo "Rendering HAProxy config..."

  RESPONSE="$(
    curl -sf \
      -X POST \
      -H "Content-Type: application/json" \
      "${ETCD_NODE}/v3/kv/range" \
      -d "{
        \"key\": \"$(b64 "${SERVICE_PREFIX}/")\",
        \"range_end\": \"$(b64 "${SERVICE_PREFIX}0")\"
      }"
  )"

  {
    cat <<'EOF'
global
    log stdout format raw local0
    maxconn 4096

defaults
    log global
    mode http
    timeout connect 5s
    timeout client 50s
    timeout server 50s

frontend http-in
    bind *:80
    default_backend app

backend app
    balance roundrobin
EOF

    # Render servers (if any)
    echo "$RESPONSE" \
      | jq -r '.kvs[]? | @base64' \
      | while read -r kv; do
          key="$(echo "$kv" | base64 -d | jq -r '.key'   | base64 -d)"
          val="$(echo "$kv" | base64 -d | jq -r '.value' | base64 -d)"
          name="$(basename "$key")"

          echo "    server ${name} ${val} check"
        done

    cat <<'EOF'

listen stats
    bind *:8404
    stats enable
    stats uri /
EOF
  } > "$TMP_CFG"

  haproxy -c -f "$TMP_CFG" >/dev/null
  mv "$TMP_CFG" "$HAPROXY_CFG"
}

# --------------------------------------------------
# Start HAProxy
# --------------------------------------------------
render_config
echo "Starting HAProxy..."
haproxy -f "$HAPROXY_CFG" -p "$HAPROXY_PID"

# --------------------------------------------------
# Watch etcd and reload HAProxy
# --------------------------------------------------
echo "Watching etcd for backend changes..."

curl -sN \
  -X POST \
  -H "Content-Type: application/json" \
  "${ETCD_NODE}/v3/watch" \
  -d "{
    \"create_request\": {
      \"key\": \"$(b64 "${SERVICE_PREFIX}/")\",
      \"range_end\": \"$(b64 "${SERVICE_PREFIX}0")\"
    }
  }" \
| while read -r _; do
    echo "etcd change detected"
    sleep 0.5
    render_config

    if [[ -f "$HAPROXY_PID" ]] && kill -0 "$(cat "$HAPROXY_PID")" 2>/dev/null; then
      echo "Reloading HAProxy..."
      haproxy -f "$HAPROXY_CFG" -p "$HAPROXY_PID" -sf "$(cat "$HAPROXY_PID")"
    else
      echo "HAProxy not running, starting fresh..."
      haproxy -f "$HAPROXY_CFG" -p "$HAPROXY_PID"
    fi
  done

