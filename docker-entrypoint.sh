#!/bin/sh
set -e

MATOMO_SRC="/usr/src/matomo/matomo"
MATOMO_DST="/home/matomo-data"

# 初回起動のみ Matomo 展開
if [ ! -f "${MATOMO_DST}/index.php" ]; then
    echo "Initializing Matomo into ${MATOMO_DST}"
    tar cf - --one-file-system -C "${MATOMO_SRC}" . | tar xf - -C "${MATOMO_DST}"
fi

exec "$@"
