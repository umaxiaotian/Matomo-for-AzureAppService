#!/bin/sh
set -e

# usage: file_env VAR [DEFAULT]
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    local varValue
    local fileVarValue

    # set -e 環境なので grep 失敗時に落ちないようにする
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

# DB env（Matomo 公式互換のパターン）
file_env 'MATOMO_DATABASE_HOST'
file_env 'MATOMO_DATABASE_USERNAME'
file_env 'MATOMO_DATABASE_PASSWORD'
file_env 'MATOMO_DATABASE_DBNAME'

WEBROOT="/var/www/html"
APP_SRC="/usr/src/matomo"
PERSIST_ROOT="/home/matomo-data"

mkdir -p "$WEBROOT" "$PERSIST_ROOT"

# ===== Azure Files の UID/GID に www-data を合わせる =====
# chmod/chown はしない。プロセス側の UID/GID を合わせる。
sync_www_data_ids() {
    # root のときだけ変更可能
    if [ "$(id -u)" != "0" ]; then
        return 0
    fi

    actual_uid="$(stat -c "%u" "$PERSIST_ROOT" 2>/dev/null || true)"
    actual_gid="$(stat -c "%g" "$PERSIST_ROOT" 2>/dev/null || true)"

    if [ -z "$actual_uid" ] || [ -z "$actual_gid" ]; then
        echo "Warning: cannot stat $PERSIST_ROOT uid/gid; skip remap."
        return 0
    fi

    # 永続側が root 所有なら Apache を root で動かす事故を避ける
    if [ "$actual_uid" -eq 0 ]; then
        echo "PERSIST_ROOT owned by root; skip remap."
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

# ===== 初回のみ: Matomo 本体を /var/www/html に展開（ローカルなので高速）=====
if [ ! -e "$WEBROOT/matomo.php" ]; then
    if [ ! -d "$APP_SRC" ]; then
        echo "Error: $APP_SRC does not exist. Matomo source not found."
        exit 1
    fi

    echo "Initializing Matomo into $WEBROOT from $APP_SRC ..."
    tar cf - --one-file-system -C "$APP_SRC" . | tar xf - -C "$WEBROOT"
fi

# ===== 永続化は /home/matomo-data に集約 =====
# Matomo が書き込む系（必要最小限）
# - config: 設定
# - tmp: キャッシュ/ログ/セッション等
# - plugins: 追加プラグイン（※初回 seed が重いなら外すのが最速）
for dir in config tmp plugins; do
    src_in_web="$WEBROOT/$dir"
    persist_dir="$PERSIST_ROOT/$dir"

    mkdir -p "$persist_dir"

    # 初回だけ: Webroot 側に実体があり、永続が空なら永続へ seed
    if [ -e "$src_in_web" ] && [ ! -L "$src_in_web" ]; then
        if [ -z "$(ls -A "$persist_dir" 2>/dev/null || true)" ]; then
            echo "Seeding persistent $dir from $src_in_web -> $persist_dir ..."
            (cd "$src_in_web" && tar cf - .) | (cd "$persist_dir" && tar xf -)
        fi
        rm -rf "$src_in_web"
    fi

    # Webroot は永続へのリンクに置換
    ln -snf "$persist_dir" "$src_in_web"
done

# tmp 配下で Matomo が期待しがちなディレクトリ（chmod/chown はしない）
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
