#!/bin/sh
set -e

file_env() {
  local var="$1"
  local fileVar="${var}_FILE"
  local def="${2:-}"
  local varValue
  local fileVarValue
  varValue=$(env | grep -E "^${var}=" | sed -E -e "s/^${var}=//") || true
  fileVarValue=$(env | grep -E "^${fileVar}=" | sed -E -e "s/^${fileVar}=//") || true

  if [ -n "${varValue}" ] && [ -n "${fileVarValue}" ]; then
    echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
    exit 1
  fi
  if [ -n "${varValue}" ]; then
    export "$var"="${varValue}"
  elif [ -n "${fileVarValue}" ]; then
    export "$var"="$(cat "${fileVarValue}")"
  elif [ -n "${def}" ]; then
    export "$var"="$def"
  fi
  unset "$fileVar"
}

file_env 'MATOMO_DATABASE_HOST'
file_env 'MATOMO_DATABASE_USERNAME'
file_env 'MATOMO_DATABASE_PASSWORD'
file_env 'MATOMO_DATABASE_DBNAME'

WEBROOT="/var/www/html"
APP_SRC="/usr/src/matomo"
PERSIST_ROOT="/home/matomo-data"

mkdir -p "$WEBROOT" "$PERSIST_ROOT"

sync_www_data_ids() {
  if [ "$(id -u)" != "0" ]; then
    return 0
  fi

  actual_uid="$(stat -c "%u" "$PERSIST_ROOT" 2>/dev/null || true)"
  actual_gid="$(stat -c "%g" "$PERSIST_ROOT" 2>/dev/null || true)"
  if [ -z "$actual_uid" ] || [ -z "$actual_gid" ]; then
    echo "Warning: cannot stat $PERSIST_ROOT uid/gid; skip remap."
    return 0
  fi

  # ✅ 0:0 は Apache が死ぬので remap しない（CI/ローカルで /home が root になるのを回避）
  if [ "$actual_uid" -eq 0 ]; then
    echo "PERSIST_ROOT owned by root (0:0); skip remap. (CI should mount volume with uid=33 gid=33)"
    return 0
  fi

  orig_uid="$(id -u www-data 2>/dev/null || true)"
  orig_gid="$(id -g www-data 2>/dev/null || true)"
  if [ -z "$orig_uid" ] || [ -z "$orig_gid" ]; then
    echo "Warning: www-data not found; skip remap."
    return 0
  fi

  if [ "$actual_uid" -eq "$orig_uid" ] && [ "$actual_gid" -eq "$orig_gid" ]; then
    echo "www-data UID/GID already match: $orig_uid:$orig_gid"
    return 0
  fi

  echo "Syncing www-data to UID=$actual_uid / GID=$actual_gid"
  command -v groupmod >/dev/null 2>&1 && groupmod -o -g "$actual_gid" www-data || true
  command -v usermod  >/dev/null 2>&1 && usermod  -o -u "$actual_uid" -g "$actual_gid" www-data || true
}

sync_www_data_ids

if [ ! -e "$WEBROOT/matomo.php" ]; then
  [ -d "$APP_SRC" ] || { echo "Error: $APP_SRC does not exist."; exit 1; }
  echo "Initializing Matomo into $WEBROOT from $APP_SRC ..."
  tar cf - --one-file-system -C "$APP_SRC" . | tar xf - -C "$WEBROOT"
fi

for dir in config tmp plugins; do
  src_in_web="$WEBROOT/$dir"
  persist_dir="$PERSIST_ROOT/$dir"
  mkdir -p "$persist_dir"

  if [ -e "$src_in_web" ] && [ ! -L "$src_in_web" ]; then
    if [ -z "$(ls -A "$persist_dir" 2>/dev/null || true)" ]; then
      echo "Seeding persistent $dir from $src_in_web -> $persist_dir ..."
      (cd "$src_in_web" && tar cf - .) | (cd "$persist_dir" && tar xf -)
    fi
    rm -rf "$src_in_web"
  fi

  ln -snf "$persist_dir" "$src_in_web"
done

mkdir -p \
  "$PERSIST_ROOT/tmp/assets" \
  "$PERSIST_ROOT/tmp/cache" \
  "$PERSIST_ROOT/tmp/logs" \
  "$PERSIST_ROOT/tmp/tcpdf" \
  "$PERSIST_ROOT/tmp/templates_c" \
  "$PERSIST_ROOT/tmp/feed" \
  "$PERSIST_ROOT/tmp/latest" \
  "$PERSIST_ROOT/tmp/climulti" \
  "$PERSIST_ROOT/tmp/sessions"

echo "Starting: $@"
exec "$@"
