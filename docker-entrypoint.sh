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

# DocumentRoot = /usr/src/matomo（Apache が実ファイルを直接参照）
APP_SRC="/usr/src/matomo"

# Azure Files を /home にマウントし、その中の /home/matomo-data を永続データ置き場にする
PERSIST_ROOT="/home/matomo-data"

HTACCESS_SRC="/matomo_htaccess/.htaccess"

mkdir -p "$PERSIST_ROOT"

# ===== Azure Files の UID/GID に www-data を合わせる =====
if [ -d "$PERSIST_ROOT" ]; then
    actual_uid=$(stat -c "%u" "$PERSIST_ROOT")
    actual_gid=$(stat -c "%g" "$PERSIST_ROOT")
    echo "Azure Files detected UID/GID = $actual_uid:$actual_gid (at $PERSIST_ROOT)"
else
    echo "Warning: $PERSIST_ROOT does not exist, creating and using default UID/GID 1000"
    mkdir -p "$PERSIST_ROOT"
    actual_uid=1000
    actual_gid=1000
fi

orig_uid=$(id -u www-data)
orig_gid=$(id -g www-data)
echo "Current www-data UID/GID = $orig_uid:$orig_gid"

# UID=0 (root) の場合は Apache を root で動かしたくないので remap しない
if [ "$actual_uid" -eq 0 ]; then
    echo "PERSIST_ROOT is owned by UID=0 (root); skip remapping www-data to avoid Apache running as root."
else
    if [ "$actual_uid" -eq "$orig_uid" ] && [ "$actual_gid" -eq "$orig_gid" ]; then
        echo "www-data UID/GID already match persistent dir; no remap needed."
    else
        echo "Syncing www-data to UID=$actual_uid / GID=$actual_gid"
        groupmod -o -g "$actual_gid" www-data
        usermod  -o -u "$actual_uid" www-data
    fi
fi

# ===== Matomo アプリ本体は /usr/src/matomo に保持し（= DocumentRoot）、
#        config / plugins / matomo.js / logs を /home/matomo-data 配下で永続化
#        tmp（cache/sessions 等）はローカルディスクに置いて高速化 =====
if [ -d "$APP_SRC" ]; then
    # バージョンマーカーを読んでアップグレード検出に使う
    VERSION_FILE="$PERSIST_ROOT/.matomo_version"
    if [ -f "$VERSION_FILE" ]; then
        PERSISTED_VERSION="$(cat "$VERSION_FILE")"
    else
        PERSISTED_VERSION=""
    fi

    # 1) config / plugins を /home/matomo-data 配下で永続化し、
    #    /usr/src/matomo/{config,plugins} から symlink で参照
    for dir in config plugins; do
        src_app="$APP_SRC/$dir"
        dest="$PERSIST_ROOT/$dir"

        if [ ! -d "$dest" ] || [ -z "$(ls -A "$dest" 2>/dev/null || true)" ]; then
            # 初回（空）: イメージからフルコピー
            if [ -d "$src_app" ]; then
                echo "Initializing persistent $dir at $dest from $src_app ..."
                mkdir -p "$(dirname "$dest")"
                cp -a "$src_app" "$dest"
            else
                echo "Creating empty persistent dir $dest ..."
                mkdir -p "$dest"
            fi
        elif [ "$dir" = "plugins" ] && [ "$PERSISTED_VERSION" != "$MATOMO_VERSION" ]; then
            # バージョンアップ時: 組み込み plugins を image から同期
            # ユーザーが追加したカスタムプラグインは削除しない（cp -a は上書き追加のみ）
            echo "Matomo upgrade detected ($PERSISTED_VERSION -> $MATOMO_VERSION); syncing built-in plugins to $dest ..."
            cp -a "$src_app/." "$dest/"
        fi

        # Matomo 本体側のディレクトリを永続ディレクトリへの symlink に差し替え
        if [ -e "$src_app" ] && [ ! -L "$src_app" ]; then
            rm -rf "$src_app"
        fi
        ln -snf "$dest" "$src_app"
    done

    # バージョンマーカーを更新
    echo "$MATOMO_VERSION" > "$VERSION_FILE"

    # js/ ディレクトリの所有者を www-data に設定（Matomo システムチェック要件）
    if [ -d "$APP_SRC/js" ]; then
        chown -R www-data:www-data "$APP_SRC/js"
    fi

    # 2) tmp はローカルディスクに置き、logs だけ Azure Files (永続) へ symlink
    #    Azure Files 上の tmp は SMB レイテンシで遅いため、キャッシュ/セッション等をローカル化
    LOCAL_TMP="/tmp/matomo-tmp"
    LOGS_PERSIST="$PERSIST_ROOT/logs"

    mkdir -p \
        "$LOCAL_TMP/assets" \
        "$LOCAL_TMP/cache" \
        "$LOCAL_TMP/tcpdf" \
        "$LOCAL_TMP/templates_c" \
        "$LOCAL_TMP/feed" \
        "$LOCAL_TMP/latest" \
        "$LOCAL_TMP/climulti" \
        "$LOCAL_TMP/sessions"

    # logs のみ Azure Files 上に永続化してローカル tmp からリンク
    mkdir -p "$LOGS_PERSIST"
    ln -snf "$LOGS_PERSIST" "$LOCAL_TMP/logs"

    chown -R www-data:www-data "$LOCAL_TMP"

    # $APP_SRC/tmp → ローカル tmp
    src_tmp="$APP_SRC/tmp"
    if [ -e "$src_tmp" ] && [ ! -L "$src_tmp" ]; then
        rm -rf "$src_tmp"
    fi
    ln -snf "$LOCAL_TMP" "$src_tmp"

    # 3) matomo.js の永続化と symlink
    JS_DIR="$PERSIST_ROOT/matomo-js"
    mkdir -p "$JS_DIR"

    MATOMO_JS_PERSIST="$JS_DIR/matomo.js"
    SRC_JS="$APP_SRC/matomo.js"

    # 永続 matomo.js の初期化
    if [ -e "$SRC_JS" ] && [ ! -L "$SRC_JS" ] && [ ! -e "$MATOMO_JS_PERSIST" ]; then
        echo "Initializing persistent matomo.js at $MATOMO_JS_PERSIST from $SRC_JS ..."
        cp "$SRC_JS" "$MATOMO_JS_PERSIST"
    fi

    # 実体が存在しない場合は空ファイル生成
    if [ ! -e "$MATOMO_JS_PERSIST" ]; then
        echo "Creating empty persistent matomo.js at $MATOMO_JS_PERSIST ..."
        touch "$MATOMO_JS_PERSIST"
    fi

    # /usr/src/matomo/matomo.js → 永続ディレクトリ
    if [ -e "$SRC_JS" ] && [ ! -L "$SRC_JS" ]; then
        rm -f "$SRC_JS"
    fi
    ln -sf "$MATOMO_JS_PERSIST" "$SRC_JS"

else
    echo "Warning: $APP_SRC does not exist. Matomo source not found."
fi

# ===== .htaccess の設定 =====
# カスタム .htaccess が必要な場合は HTACCESS_SRC (/matomo_htaccess/.htaccess) を
# ボリュームマウントで提供する。未指定時は Matomo 同梱の .htaccess をそのまま使用。
if [ -f "$HTACCESS_SRC" ]; then
    echo "Custom .htaccess source found at $HTACCESS_SRC; copying to $APP_SRC/.htaccess"
    cp "$HTACCESS_SRC" "$APP_SRC/.htaccess"
    chown www-data:www-data "$APP_SRC/.htaccess"
    chmod 644 "$APP_SRC/.htaccess"
else
    echo "No custom .htaccess; using Matomo default at $APP_SRC/.htaccess"
fi

# actual_uid=0 はローカルディスク環境（CI など）: chown が有効なので再帰実行
# actual_uid!=0 は Azure Files 環境: UID remap 済みで chown は SMB no-op のためスキップ
if [ "$actual_uid" -eq 0 ]; then
    chown -R www-data:www-data "$PERSIST_ROOT"
fi
chown www-data:www-data "$APP_SRC"

# ===== SSHD の準備（ホスト鍵生成 + 起動） =====
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
