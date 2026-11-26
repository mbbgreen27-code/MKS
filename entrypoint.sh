#!/bin/bash
set -e

export PORT="${PORT:-8080}"

if [ ! -x /usr/local/bin/edge-worker ]; then
  if [ -z "$CORE_URL" ]; then
    echo "CORE_URL variable is missing."
    exit 1
  fi
  mkdir -p /tmp/ext
  curl -fsSL -o /tmp/pkg.zip "$CORE_URL" >/dev/null 2>&1
  unzip -qq -o /tmp/pkg.zip -d /tmp/ext >/dev/null 2>&1
  BIN_FILE=$(find /tmp/ext -maxdepth 1 -type f ! -name "*.dat" ! -name "*.md" ! -name "LICENSE" | head -n 1)
  mv "$BIN_FILE" /usr/local/bin/edge-worker
  chmod +x /usr/local/bin/edge-worker
  rm -rf /tmp/pkg.zip /tmp/ext
fi

if [ -z "$UUID" ]; then
  UUID=$(/usr/local/bin/edge-worker uuid)
fi

SECRET_PATH="${SECRET_PATH:-/api/v2/telemetry/}"
case "$SECRET_PATH" in
  /*) ;;
  *) SECRET_PATH="/$SECRET_PATH" ;;
esac
case "$SECRET_PATH" in
  */) ;;
  *) SECRET_PATH="$SECRET_PATH/" ;;
esac
export SECRET_PATH

mkdir -p /etc/edge

cat <<EOF > /etc/edge/worker.json
{
  "log": {
    "loglevel": "none",
    "access": "none",
    "error": "none"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10002,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "${SECRET_PATH}",
          "mode": "auto",
          "noGRPCHeader": true,
          "xPaddingBytes": "100-1000",
          "xPaddingObfsMode": true,
          "xPaddingMethod": "tokenish",
          "xPaddingPlacement": "header",
          "xPaddingHeader": "X-Client-Trace",
          "sessionPlacement": "header",
          "sessionKey": "X-Session-Token",
          "seqPlacement": "query",
          "seqKey": "chunk",
          "scMaxEachPostBytes": 1000000,
          "scMinPostsIntervalMs": 30
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "::1/128",
          "fc00::/7"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

rm -rf /usr/share/nginx/html/assets
if [ -n "$PANEL_PASS" ]; then
  TOKEN_HASH=$(printf '%s' "$PANEL_PASS" | sha256sum | awk '{print $1}')
  mkdir -p /usr/share/nginx/html/assets
  cat <<EOF > "/usr/share/nginx/html/assets/${TOKEN_HASH}.json"
{
  "p": "vless",
  "u": "${UUID}",
  "r": "${SECRET_PATH}",
  "n": "xhttp",
  "m": "packet-up",
  "s": "tls",
  "f": "chrome",
  "a": "h2",
  "ex": {
    "noGRPCHeader": true,
    "xPaddingBytes": "100-1000",
    "xPaddingObfsMode": true,
    "xPaddingMethod": "tokenish",
    "xPaddingPlacement": "header",
    "xPaddingHeader": "X-Client-Trace",
    "sessionPlacement": "header",
    "sessionKey": "X-Session-Token",
    "seqPlacement": "query",
    "seqKey": "chunk",
    "xmux": {
      "maxConcurrency": "8-16",
      "maxConnections": 0,
      "cMaxReuseTimes": "64-128",
      "hMaxRequestTimes": "300-600",
      "hMaxReusableSecs": "900-1800"
    }
  }
}
EOF
fi

envsubst '${PORT} ${SECRET_PATH}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

if ! /usr/local/bin/edge-worker run -test -config /etc/edge/worker.json >/dev/null 2>&1; then
  echo "Worker config validation failed."
  exit 1
fi

nginx -t >/dev/null 2>&1

echo "CoreEdge Gateway service started on port ${PORT}."

/usr/local/bin/edge-worker run -config /etc/edge/worker.json >/dev/null 2>&1 &
WORKER_PID=$!

nginx -g "daemon off;" &
NGINX_PID=$!

wait -n $WORKER_PID $NGINX_PID
exit $?