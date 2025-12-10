#!/bin/sh
set -e

# usage: file_env VAR [DEFAULT]
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

# DB 関連 env 読み込み
file_env 'MATOMO_DATABASE_HOST'
file_env 'MATOMO_DATABASE_USERNAME'
file_env 'MATOMO_DATABASE_PASSWORD'
file_env 'MATOMO_DATABASE_DBNAME'

WEBROOT="/var/www/html"
APP_SRC="/usr/src/matomo"

# Azure Files を /home にマウントし、その中の /home/matomo を永続データ置き場にする
PERSIST_ROOT="/home/matomo"

# matomo.js 永続化用（実体）
MATOMO_JS_PERSIST="$PERSIST_ROOT/matomo.js"

HTACCESS_SRC="/matomo_htaccess/.htaccess"
HTACCESS_DEST="$WEBROOT/.htaccess"

mkdir -p "$WEBROOT"
mkdir -p "$PERSIST_ROOT"

# ===== Azure Files の UID/GID に www-data を合わせる =====
#   ※ Azure 側で /home にマウントしている想定なので、/home/matomo の UID/GID を見る
if [ -d "$PERSIST_ROOT" ]; then
    actual_uid=$(stat -c "%u" "$PERSIST_ROOT")
    actual_gid=$(stat -c "%g" "$PERSIST_ROOT")
    echo "Azure Files detected UID/GID = $actual_uid:$actual_gid (at $PERSIST_ROOT)"
else
    echo "Warning: $PERSIST_ROOT does not exist, defaulting to UID/GID 1000"
    actual_uid=1000
    actual_gid=1000
    mkdir -p "$PERSIST_ROOT"
fi

echo "Syncing www-data to UID=$actual_uid / GID=$actual_gid"
groupmod -o -g "$actual_gid" www-data
usermod  -o -u "$actual_uid" www-data

# ===== Matomo アプリ本体は /usr/src/matomo に保持し、
#        config / tmp / plugins / matomo.js を /home/matomo 配下で永続化 =====
if [ -d "$APP_SRC" ]; then
    # 1) /home/matomo/config /tmp /plugins を実体として用意し、
    #    /usr/src/matomo と /var/www/html の両方からシンボリックリンクで参照する
    for dir in config tmp plugins; do
        src_app="$APP_SRC/$dir"
        dest="$PERSIST_ROOT/$dir"
        web_dir="$WEBROOT/$dir"

        # 永続ディレクトリを作成
        if [ ! -d "$dest" ]; then
            echo "Creating persistent dir at $dest ..."
            mkdir -p "$dest"
        fi

        # Matomo 本体側のディレクトリを永続ディレクトリへのシンボリックリンクに差し替え
        if [ -e "$src_app" ] && [ ! -L "$src_app" ]; then
            rm -rf "$src_app"
        fi
        ln -snf "$dest" "$src_app"

        # Web ルート側にも同じ永続ディレクトリへのシンボリックリンクを張る
        if [ -e "$web_dir" ] && [ ! -L "$web_dir" ]; then
            rm -rf "$web_dir"
        fi
        ln -snf "$dest" "$web_dir"
    done

    # 2) /usr/src/matomo 以下のアプリ本体を /var/www/html へシンボリックリンクとして公開
    #    （config / tmp / plugins / matomo.js は除外）
    for item in "$APP_SRC"/*; do
        base="$(basename "$item")"
        case "$base" in
            config|tmp|plugins|matomo.js) continue ;;
        esac

        target="$WEBROOT/$base"
        if [ ! -e "$target" ]; then
            ln -s "$item" "$target"
        fi
    done

    # 3) tmp 配下に assets などを書き込み可能ディレクトリとして用意
    TMP_DEST="$PERSIST_ROOT/tmp"
    if [ -d "$TMP_DEST" ]; then
        mkdir -p \
            "$TMP_DEST/assets" \
            "$TMP_DEST/cache" \
            "$TMP_DEST/logs" \
            "$TMP_DEST/tcpdf" \
            "$TMP_DEST/templates_c" \
            "$TMP_DEST/feed" \
            "$TMP_DEST/latest" \
            "$TMP_DEST/climulti" \
            "$TMP_DEST/sessions"
        # 書き込みできるようにパーミッション調整（Azure Files 側でも 0775/0777 想定）
        chmod -R 0775 "$TMP_DEST" || true
    fi

    # 4) matomo.js の永続化とシンボリックリンク設定
    SRC_JS="$APP_SRC/matomo.js"
    WEBROOT_JS="$WEBROOT/matomo.js"

    # 永続 matomo.js 実体の初期化
    if [ -e "$SRC_JS" ] && [ ! -e "$MATOMO_JS_PERSIST" ]; then
        echo "Initializing persistent matomo.js at $MATOMO_JS_PERSIST from $SRC_JS ..."
        cp "$SRC_JS" "$MATOMO_JS_PERSIST"
    fi

    # イメージにも永続ディレクトリにも matomo.js が無い場合は、空ファイルを作っておく
    if [ ! -e "$MATOMO_JS_PERSIST" ]; then
        echo "No matomo.js found in image or persistent dir; creating empty $MATOMO_JS_PERSIST ..."
        touch "$MATOMO_JS_PERSIST"
    fi

    # /usr/src/matomo/matomo.js を永続ファイルへのシンボリックリンクに差し替え
    if [ -e "$SRC_JS" ] && [ ! -L "$SRC_JS" ]; then
        rm -f "$SRC_JS"
    fi
    ln -sf "$MATOMO_JS_PERSIST" "$SRC_JS"

    # Web ルート直下の matomo.js も永続ファイルへのシンボリックリンクにする
    if [ -e "$WEBROOT_JS" ] && [ ! -L "$WEBROOT_JS" ]; then
        rm -f "$WEBROOT_JS"
    fi
    ln -sf "$MATOMO_JS_PERSIST" "$WEBROOT_JS"
else
    echo "Warning: $APP_SRC does not exist. Matomo source not found."
fi

# 永続ディレクトリと Web ルートの owner を www-data に
chown -R www-data:www-data "$PERSIST_ROOT" "$WEBROOT"

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

# ===== /matomo_htaccess/.htaccess があれば、それを使う =====
if [ -f "$HTACCESS_SRC" ]; then
    echo "Custom .htaccess found at $HTACCESS_SRC, copying to $HTACCESS_DEST"
    cp "$HTACCESS_SRC" "$HTACCESS_DEST"
    chown www-data:www-data "$HTACCESS_DEST"
else
    echo "No custom .htaccess found at $HTACCESS_SRC, skipping copy."
fi

echo "Starting: $@"
exec "$@"
