#!/bin/sh
set -eu

MATOMO_SRC_DIR="/usr/src/matomo"
MATOMO_DATA_DIR="/home/matomo-data"
WEB_ROOT="/var/www/html"

echo "== php -v =="
php -v

echo "== php -m =="
php -m

echo "== init =="
echo "MATOMO_SRC_DIR=${MATOMO_SRC_DIR}"
echo "MATOMO_DATA_DIR=${MATOMO_DATA_DIR}"
echo "WEB_ROOT=${WEB_ROOT}"

mkdir -p "${MATOMO_DATA_DIR}"

if [ ! -d "${MATOMO_SRC_DIR}" ]; then
  echo "ERROR: Matomo source directory not found: ${MATOMO_SRC_DIR}"
  echo "Debug: ls -al /usr/src"
  ls -al /usr/src || true
  exit 1
fi

if [ ! -f "${MATOMO_SRC_DIR}/matomo.php" ]; then
  echo "ERROR: Matomo source seems broken: ${MATOMO_SRC_DIR}/matomo.php not found"
  echo "Debug: ls -al ${MATOMO_SRC_DIR}"
  ls -al "${MATOMO_SRC_DIR}" || true
  exit 1
fi

# Azure Files などのマウントで空なら初期コピーする
if [ ! -f "${MATOMO_DATA_DIR}/matomo.php" ]; then
  echo "Matomo not found in data dir. Copying from image to data dir..."
  cp -a "${MATOMO_SRC_DIR}/." "${MATOMO_DATA_DIR}/"
  chown -R www-data:www-data "${MATOMO_DATA_DIR}"
else
  echo "Matomo already initialized in data dir. Skipping copy."
fi

# Apacheの公開ルートを data に向ける（シンボリックリンクでOK）
if [ -d "${WEB_ROOT}" ] || [ -L "${WEB_ROOT}" ]; then
  rm -rf "${WEB_ROOT}"
fi

ln -s "${MATOMO_DATA_DIR}" "${WEB_ROOT}"
chown -h www-data:www-data "${WEB_ROOT}"

echo "== final check =="
ls -al "${WEB_ROOT}" || true
test -f "${WEB_ROOT}/matomo.php"

echo "== exec =="
exec "$@"
