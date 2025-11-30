#!/bin/sh
set -e

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
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

# /var/www/html 全体の owner を www-data に
chown -R www-data:www-data "$WEBROOT"

# ===== SSHD を起動 (ポート 2222, root/Docker!) =====
# sshd_config で Port 2222, PermitRootLogin yes, PasswordAuthentication yes を指定済み
if [ ! -d "/var/run/sshd" ]; then
    mkdir -p /var/run/sshd
fi

echo "Starting sshd on port 2222..."
/usr/sbin/sshd -D &

# ===== Matomo 初回展開処理 =====
if [ ! -e matomo.php ]; then
    uid="$(id -u)"
    gid="$(id -g)"
    if [ "$uid" = '0' ]; then
        case "$1" in
            apache2*)
                user="${APACHE_RUN_USER:-www-data}"
                group="${APACHE_RUN_GROUP:-www-data}"

                # strip off any '#' symbol ('#1000' is valid syntax for Apache)
                user="${user#'#'}"
                group="${group#'#'}"
                ;;
            *) # php-fpm を使う場合
                user='www-data'
                group='www-data'
                ;;
        esac
    else
        user="$uid"
        group="$gid"
    fi

    echo "Extracting Matomo into $PWD..."
    tar cf - --one-file-system -C /usr/src/matomo . | tar xf -
    chown -R "$user":"$group" .
fi

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
