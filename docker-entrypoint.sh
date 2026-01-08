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

file_env 'MATOMO_DATABASE_HOST'
file_env 'MATOMO_DATABASE_USERNAME'
file_env 'MATOMO_DATABASE_PASSWORD'
file_env 'MATOMO_DATABASE_DBNAME'

# ---------------------------
# Azure Files 対策:
# /var/www/html の uid/gid に www-data の uid/gid を合わせる（chmod/chownしない）
# ---------------------------
sync_www_data_ids() {
	# root のときだけユーザーIDを変更できる
	if [ "$(id -u)" != "0" ]; then
		return 0
	fi

	# stat が無い/失敗する環境もあるのでフォールバック
	target_uid="$(stat -c '%u' /var/www/html 2>/dev/null || true)"
	target_gid="$(stat -c '%g' /var/www/html 2>/dev/null || true)"

	# 取れなければ何もしない
	if [ -z "$target_uid" ] || [ -z "$target_gid" ]; then
		return 0
	fi

	current_uid="$(id -u www-data 2>/dev/null || true)"
	current_gid="$(id -g www-data 2>/dev/null || true)"

	# www-data が存在しない/取得できないなら何もしない
	if [ -z "$current_uid" ] || [ -z "$current_gid" ]; then
		return 0
	fi

	# すでに一致してるなら何もしない
	if [ "$current_uid" = "$target_uid" ] && [ "$current_gid" = "$target_gid" ]; then
		return 0
	fi

	# groupmod/usermod がある前提（Debian/Ubuntu系の公式イメージでだいたいOK）
	# 競合があっても -o で上書き許可（コンテナ内なので割り切り）
	if command -v groupmod >/dev/null 2>&1; then
		groupmod -o -g "$target_gid" www-data || true
	fi
	if command -v usermod >/dev/null 2>&1; then
		usermod  -o -u "$target_uid" -g "$target_gid" www-data || true
	fi
}

sync_www_data_ids

if [ ! -e matomo.php ]; then
	uid="$(id -u)"
	gid="$(id -g)"

	if [ "$uid" = '0' ]; then
		case "$1" in
			apache2*)
				user="${APACHE_RUN_USER:-www-data}"
				group="${APACHE_RUN_GROUP:-www-data}"
				user="${user#'#'}"
				group="${group#'#'}"
				;;
			*) # php-fpm
				user='www-data'
				group='www-data'
				;;
		esac
	else
		user="$uid"
		group="$gid"
	fi

	tar cf - --one-file-system -C /usr/src/matomo . | tar xf -

	# Azure Files では chown が失敗することがあるので、失敗しても落とさない
	# （set -e を維持したいので、ここだけ "|| true" を付ける）
	chown -R "$user":"$group" . 2>/dev/null || true
fi

exec "$@"
