#!/bin/sh
set -e

MATOMO_DATA="${MATOMO_DATA:-/home/matomo-data}"
MATOMO_WEBROOT="${MATOMO_WEBROOT:-/home/matomo-data/www}"
APP_SRC="${APP_SRC:-/usr/src/matomo}"

mkdir -p "$MATOMO_DATA" "$MATOMO_WEBROOT"

# ここでは chmod/chown はしない（要件通り）
# ただし「書けない」と必ず落ちるので、早期に分かるようにテストだけする
can_write() {
  target="$1"
  mkdir -p "$target"
  touch "$target/.writetest" 2>/dev/null && rm -f "$target/.writetest" 2>/dev/null
}

if ! can_write "$MATOMO_DATA"; then
  echo >&2 "ERROR: $MATOMO_DATA is not writable by current user: $(id -u):$(id -g)"
  echo >&2 "Hint: mount volume with uid/gid=33:33 (www-data) or configure storage permissions."
  exit 1
fi

# 初回だけ /home/matomo-data/www に Matomo を展開
if [ ! -e "$MATOMO_WEBROOT/matomo.php" ]; then
  echo "Initializing Matomo into $MATOMO_WEBROOT from $APP_SRC ..."
  # /usr/src/matomo 配下は matomo/ なので注意
  if [ -d "$APP_SRC/matomo" ]; then
    tar cf - --one-file-system -C "$APP_SRC/matomo" . | tar xf - -C "$MATOMO_WEBROOT"
  else
    # 何かの都合で直下にある場合
    tar cf - --one-file-system -C "$APP_SRC" . | tar xf - -C "$MATOMO_WEBROOT"
  fi
fi

# 必要ディレクトリを /home/matomo-data 配下に固定（Matomoが必ず触る場所）
mkdir -p \
  "$MATOMO_WEBROOT/config" \
  "$MATOMO_WEBROOT/tmp" \
  "$MATOMO_WEBROOT/tmp/assets" \
  "$MATOMO_WEBROOT/tmp/cache" \
  "$MATOMO_WEBROOT/tmp/logs" \
  "$MATOMO_WEBROOT/tmp/tcpdf" \
  "$MATOMO_WEBROOT/tmp/templates_c" \
  "$MATOMO_WEBROOT/tmp/sessions"

# ここも chmod/chown はしないが、最低限 “書けるか” だけ検証
for p in \
  "$MATOMO_WEBROOT/config" \
  "$MATOMO_WEBROOT/tmp" \
  "$MATOMO_WEBROOT/tmp/cache" \
  "$MATOMO_WEBROOT/tmp/logs" \
  "$MATOMO_WEBROOT/tmp/templates_c"
do
  if ! can_write "$p"; then
    echo >&2 "ERROR: $p is not writable. Matomo will 500."
    exit 1
  fi
done

echo "Starting: $@"
exec "$@"
