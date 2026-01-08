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

# DB 関連 env 読み込み
file_env 'MATOMO_DATABASE_HOST'
file_env 'MATOMO_DATABASE_USERNAME'
file_env 'MATOMO_DATABASE_PASSWORD'
file_env 'MATOMO_DATABASE_DBNAME'

WEBROOT="/var/www/html"
APP_SRC="/usr/src/matomo"
PERSIST_ROOT="/home/matomo-data"

mkdir -p "$WEBROOT"
mkdir -p "$PERSIST_ROOT"

# ===== Azure Files の UID/GID に www-data を合わせる =====
# （chmod/chown はしない。プロセス側の UID/GID を合わせる）
sync_www_data_ids() {
    # root のときだけ変更可能
    if [ "$(id -u)" != "0" ]; then
        return 0
    fi

    actual_uid="$(stat -c "%u" "$PERSIST_ROOT" 2>/dev/null || true)"
    actual_gid="$(stat -c "%g" "$PERSIST_ROOT" 2>/dev/null || true)"

    # 取れない場合はスキップ
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

# ===== 初回のみ: Matomo 本体を /var/www/html に展開（ローカルなので速い）=====
# 以降は /home/matomo-data 配下の永続データをリンクして運用
if [ ! -e "$WEBROOT/matomo.php" ]; then
    if [ ! -d "$APP_SRC" ]; then
        echo "Error: $APP_SRC does not exist. Matomo source not found."
        exit 1
    fi

    echo "Initializing Matomo into $WEBROOT from $APP_SRC ..."
    # 元 entrypoint と同じ tar 展開
    tar cf - --one-file-system -C "$APP_SRC" . | tar xf - -C "$WEBROOT"

    # chown は Azure Files で遅い/効かないことがあるので “やらない”
    # （必要なら /var/www/html がローカルなのでここは軽いが、要件に合わせて削除）
fi

# ===== 永続化（全部 /home/matomo-data に集約）=====
# Matomo が書き込む系を永続に逃がす（必要最小限。ここは好みで増やせる）
# - config: 設定
# - tmp: キャッシュ/ログ/セッション等
# - plugins: 追加プラグインの永続化（※初回コピーが重いなら後で外すのが最速）
for dir in config tmp plugins; do
    src_in_web="$WEBROOT/$dir"
    persist_dir="$PERSIST_ROOT/$dir"

    mkdir -p "$persist_dir"

    # 初回だけ: Webroot 側に既存があり、永続が空なら永続へ移す（ローカル→Azure なので最小限に）
    if [ -e "$src_in_web" ] && [ ! -L "$src_in_web" ]; then
        if [ -z "$(ls -A "$persist_dir" 2>/dev/null || true)" ]; then
            echo "Seeding persistent $dir from $src_in_web -> $persist_dir ..."
            # cp -a より tar の方が速いことが多い
            (cd "$src_in_web" && tar cf - .) | (cd "$persist_dir" && tar xf -)
        fi

        # Webroot 側は削除してリンクに置き換え
        rm -rf "$src_in_web"
    fi

    ln -snf "$persist_dir" "$src_in_web"
done

# tmp 配下で Matomo が期待しがちなディレクトリは作っておく（chmod/chown はしない）
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

# ===== SSHD の準備（元のまま） =====
if [ ! -d "/var/run/sshd" ]; then
    mkdir -p /var/run/sshd
fi

if command -v ssh-keygen >/dev/null 2>&1; then
    if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
        echo "No SSH host keys found, generating with ssh-keygen -A..."
        ssh-keygen -A
    else
        echo "SSH host keys already exist, skipping generation."
    fi
else
    echo "Warning: ssh-keygen not found; SSH host keys will not be generated."
fi

echo "Starting sshd on port 2222..."
/usr/sbin/sshd -D &

echo "Starting: $@"
exec "$@"
