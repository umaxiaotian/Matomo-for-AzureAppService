#!/bin/sh
set -e

# usage: file_env VAR [DEFAULT]
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    local varValue=$(env | grep -E "^${var}=" | sed -E -e "s/^${var}=//")
    local fileVarValue=$(env | grep -E "^${fileVar}=" | sed -E -e "s/^${fileVar}=//")
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
TARGET="$WEBROOT/tmp"
HTACCESS_SRC="/matomo_htaccess/.htaccess"
HTACCESS_DEST="$WEBROOT/.htaccess"
MATOMO_SRC="/usr/src/matomo"

# matomo.js 永続化用ディレクトリ（ここに Azure Files をマウントする想定）
MATOMO_JS_DIR="$WEBROOT/matomo-js"

mkdir -p "$WEBROOT"

# ===== Azure Files の UID/GID に www-data を合わせる =====
if [ -d "$TARGET" ]; then
    actual_uid=$(stat -c "%u" "$TARGET")
    actual_gid=$(stat -c "%g" "$TARGET")
    echo "Azure Files detected UID/GID = $actual_uid:$actual_gid"
else
    echo "Warning: $TARGET does not exist, defaulting to UID/GID 1000"
    actual_uid=1000
    actual_gid=1000
fi

echo "Syncing www-data to UID=$actual_uid / GID=$actual_gid"
groupmod -o -g "$actual_gid" www-data
usermod  -o -u "$actual_uid" www-data

# ===== Matomo アプリ本体は /usr/src/matomo に保持し、
#        config / tmp / plugins だけを /var/www/html 配下に実体として置く =====
if [ -d "$MATOMO_SRC" ]; then
    # 1) config / tmp / plugins を /var/www/html に実体として用意
    for dir in config tmp plugins; do
        src="$MATOMO_SRC/$dir"
        dest="$WEBROOT/$dir"

        if [ "$dir" = "tmp" ]; then
            # tmp はコピーせず、毎回空を前提に Azure Files 側で使う
            if [ ! -d "$dest" ]; then
                echo "Creating tmp dir at $dest ..."
                mkdir -p "$dest"
            fi
        else
            # config / plugins はイメージから初期コピー
            if [ ! -e "$dest" ]; then
                if [ -e "$src" ]; then
                    echo "Initializing $dest from $src ..."
                    cp -a "$src" "$dest"
                else
                    echo "Creating empty directory $dest ..."
                    mkdir -p "$dest"
                fi
            fi
        fi

        # Matomo 本体側のディレクトリは /var/www/html 側へのシンボリックリンクに差し替え
        if [ -e "$src" ] && [ ! -L "$src" ]; then
            rm -rf "$src"
        fi
        ln -snf "$dest" "$src"
    done

    # 2) /usr/src/matomo 以下のアプリ本体を /var/www/html へシンボリックリンクとして公開
    #    （config / tmp / plugins / matomo.js は除外）
    for item in "$MATOMO_SRC"/*; do
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
    TMP_DEST="$WEBROOT/tmp"
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
    mkdir -p "$MATOMO_JS_DIR"

    SRC_JS="$MATOMO_SRC/matomo.js"
    PERSIST_JS="$MATOMO_JS_DIR/matomo.js"
    WEBROOT_JS="$WEBROOT/matomo.js"

    if [ -e "$SRC_JS" ] && [ ! -e "$PERSIST_JS" ]; then
        echo "Initializing persistent matomo.js at $PERSIST_JS from $SRC_JS ..."
        cp "$SRC_JS" "$PERSIST_JS"
    fi

    # イメージにも永続ディレクトリにも matomo.js が無い場合は、空ファイルを作っておく
    if [ ! -e "$PERSIST_JS" ]; then
        echo "No matomo.js found in image or persistent dir; creating empty $PERSIST_JS ..."
        touch "$PERSIST_JS"
    fi

    # /usr/src/matomo/matomo.js を永続ファイルへのシンボリックリンクに差し替え
    if [ -e "$SRC_JS" ] && [ ! -L "$SRC_JS" ]; then
        rm -f "$SRC_JS"
    fi
    ln -sf "$PERSIST_JS" "$SRC_JS"

    # Web ルート直下の matomo.js も永続ファイルへのシンボリックリンクにする
    if [ -e "$WEBROOT_JS" ] && [ ! -L "$WEBROOT_JS" ]; then
        rm -f "$WEBROOT_JS"
    fi
    ln -sf "$PERSIST_JS" "$WEBROOT_JS"
else
    echo "Warning: $MATOMO_SRC does not exist. Matomo source not found."
fi

# /var/www/html 全体の owner を www-data に（Azure Files 側の UID/GID に同期済み）
chown -R www-data:www-data "$WEBROOT"

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
