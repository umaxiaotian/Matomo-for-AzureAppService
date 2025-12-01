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
MATOMO_SRC="/usr/src/matomo"
HTACCESS_SRC="/matomo_htaccess/.htaccess"
HTACCESS_DEST="$WEBROOT/.htaccess"

mkdir -p "$WEBROOT"

# ===== Azure Files の UID/GID に www-data を合わせる =====
TARGET="$WEBROOT/tmp"
if [ -d "$TARGET" ]; then
    actual_uid=$(stat -c "%u" "$TARGET")
    actual_gid=$(stat -c "%g" "$TARGET")
    echo "Azure Files detected UID/GID from $TARGET = $actual_uid:$actual_gid"
else
    echo "Warning: $TARGET does not exist, defaulting to UID/GID 1000:1000"
    actual_uid=1000
    actual_gid=1000
fi

echo "Syncing www-data to UID=$actual_uid / GID=$actual_gid"
groupmod -o -g "$actual_gid" www-data
usermod  -o -u "$actual_uid" www-data

# ===== Matomo アプリ本体は /usr/src/matomo に保持し、
#        config / tmp / plugins だけを /var/www/html 側に実体として永続化 =====
if [ -d "$MATOMO_SRC" ]; then
    for dir in config tmp plugins; do
        src="$MATOMO_SRC/$dir"
        dest="$WEBROOT/$dir"

        # /var/www/html 側の永続ディレクトリを初期化（初回のみコピー）
        if [ ! -e "$dest" ]; then
            if [ -e "$src" ]; then
                echo "Initializing $dest from $src ..."
                cp -a "$src" "$dest"
            else
                echo "Creating empty directory $dest ..."
                mkdir -p "$dest"
            fi
        fi

        # /usr/src/matomo 側は /var/www/html 側へのシンボリックリンクに差し替え
        if [ -e "$src" ] && [ ! -L "$src" ]; then
            echo "Linking $src -> $dest"
            rm -rf "$src"
            ln -s "$dest" "$src"
        fi
    done

    # ===== /usr/src/matomo 以下の「コア」ファイル・ディレクトリを
    #        /var/www/html 側にシンボリックリンクとして公開（config/tmp/plugins は除外） =====
    for item in "$MATOMO_SRC"/*; do
        base="$(basename "$item")"
        case "$base" in
            config|tmp|plugins)
                # これらは /var/www/html 側に実体として存在させるのでスキップ
                continue
                ;;
        esac

        target="$WEBROOT/$base"
        if [ ! -e "$target" ]; then
            echo "Creating symlink $target -> $item"
            ln -s "$item" "$target"
        fi
    done
else
    echo "Warning: $MATOMO_SRC does not exist. Matomo source not found."
fi

# ===== /var/www/html/tmp の権限を Apache (www-data) に合わせる =====
if [ -d "$WEBROOT/tmp" ]; then
    echo "Fixing permissions for $WEBROOT/tmp ..."
else
    echo "Creating $WEBROOT/tmp ..."
    mkdir -p "$WEBROOT/tmp"
fi
chown -R www-data:www-data "$WEBROOT/tmp"
chmod -R 775 "$WEBROOT/tmp"

# ===== /matomo_htaccess/.htaccess があれば、それを使う =====
if [ -f "$HTACCESS_SRC" ]; then
    echo "Custom .htaccess found at $HTACCESS_SRC, copying to $HTACCESS_DEST"
    cp "$HTACCESS_SRC" "$HTACCESS_DEST"
    chown www-data:www-data "$HTACCESS_DEST"
else
    echo "No custom .htaccess found at $HTACCESS_SRC, skipping copy."
fi

# /var/www/html 全体の owner を www-data に
echo "Setting ownership of $WEBROOT to www-data..."
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

echo "Starting: $@"
exec "$@"
