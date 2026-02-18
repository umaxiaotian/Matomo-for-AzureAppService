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

# Azure Files を /home にマウントし、その中の /home/matomo-data を永続データ置き場にする
PERSIST_ROOT="/home/matomo-data"

# 旧: /matomo_htaccess/.htaccess から読み込む想定だったソース（ある場合は初期化に利用）
HTACCESS_SRC="/matomo_htaccess/.htaccess"
HTACCESS_PERSIST_DIR="$PERSIST_ROOT/htaccess"
HTACCESS_PERSIST="$HTACCESS_PERSIST_DIR/.htaccess"
HTACCESS_DEST="$WEBROOT/.htaccess"

mkdir -p "$WEBROOT"
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

# ===== Matomo アプリ本体は /usr/src/matomo に保持し、
#        config / tmp / plugins / matomo.js を /home/matomo-data 配下で永続化 =====
if [ -d "$APP_SRC" ]; then
    # 1) /home/matomo-data/config /tmp /plugins を実体として用意し、
    #    /usr/src/matomo と /var/www/html の両方からシンボリックリンクで参照する
    for dir in config tmp plugins; do
        src_app="$APP_SRC/$dir"
        dest="$PERSIST_ROOT/$dir"
        web_dir="$WEBROOT/$dir"

        # 永続ディレクトリ初期化
        if [ "$dir" = "tmp" ]; then
            # tmp は空でOK（Matomo が勝手に使う）
            [ -d "$dest" ] || mkdir -p "$dest"
        else
            # config / plugins はイメージから初回コピー（既に中身があればそのまま）
            if [ ! -d "$dest" ] || [ -z "$(ls -A "$dest" 2>/dev/null || true)" ]; then
                if [ -d "$src_app" ]; then
                    echo "Initializing persistent $dir at $dest from $src_app ..."
                    mkdir -p "$(dirname "$dest")"
                    cp -a "$src_app" "$dest"
                else
                    echo "Creating empty persistent dir $dest ..."
                    mkdir -p "$dest"
                fi
            fi
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
        chmod -R 0775 "$TMP_DEST" || true
    fi

    # 4) matomo.js の永続化とシンボリックリンク設定
    JS_DIR="$PERSIST_ROOT/matomo-js"
    mkdir -p "$JS_DIR"

    MATOMO_JS_PERSIST="$JS_DIR/matomo.js"
    SRC_JS="$APP_SRC/matomo.js"
    WEBROOT_JS="$WEBROOT/matomo.js"

    # 永続 matomo.js の初期化
    if [ -e "$SRC_JS" ] && [ ! -e "$MATOMO_JS_PERSIST" ]; then
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

    # /var/www/html/matomo.js → 永続ディレクトリ
    if [ -e "$WEBROOT_JS" ] && [ ! -L "$WEBROOT_JS" ]; then
        rm -f "$WEBROOT_JS"
    fi
    ln -sf "$MATOMO_JS_PERSIST" "$WEBROOT_JS"
else
    echo "Warning: $APP_SRC does not exist. Matomo source not found."
fi

# ===== .htaccess の永続化とリンク設定 (/home/matomo-data 配下に保存) =====
mkdir -p "$HTACCESS_PERSIST_DIR"

if [ -f "$HTACCESS_SRC" ]; then
    echo "Custom .htaccess source found at $HTACCESS_SRC"
    if [ ! -f "$HTACCESS_PERSIST" ]; then
        echo "Initializing persistent .htaccess at $HTACCESS_PERSIST from $HTACCESS_SRC ..."
        cp "$HTACCESS_SRC" "$HTACCESS_PERSIST"
    fi
else
    echo "No custom .htaccess source at $HTACCESS_SRC"
    if [ ! -f "$HTACCESS_PERSIST" ]; then
        echo "Creating empty persistent .htaccess at $HTACCESS_PERSIST ..."
        touch "$HTACCESS_PERSIST"
    fi
fi

# /var/www/html/.htaccess を永続ファイルへのシンボリックリンクにする
if [ -e "$HTACCESS_DEST" ] && [ ! -L "$HTACCESS_DEST" ]; then
    rm -f "$HTACCESS_DEST"
fi
ln -sf "$HTACCESS_PERSIST" "$HTACCESS_DEST"

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

echo "Starting: $@"
exec "$@"
