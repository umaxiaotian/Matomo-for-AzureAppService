FROM php:8.4-apache

ARG MATOMO_VERSION=5.6.1

ENV MATOMO_HOME=/home/matomo-data \
    APACHE_DOCUMENT_ROOT=/home/matomo-data

# Apache DocumentRoot を変更
RUN set -eux; \
    sed -ri "s!/var/www/html!${APACHE_DOCUMENT_ROOT}!g" \
        /etc/apache2/sites-available/*.conf \
        /etc/apache2/apache2.conf

# 必要パッケージ（※ gpg は purge 前に使う）
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        dirmngr \
        libzip-dev \
        libpng-dev \
        libjpeg-dev \
        libfreetype6-dev \
        libonig-dev \
        libldap2-dev \
        libzstd-dev \
        liblz4-dev \
        pkg-config \
        unzip; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j$(nproc) \
        gd \
        mysqli \
        pdo_mysql \
        zip \
        ldap \
        opcache \
        bcmath

# PECL extensions
RUN set -eux; \
    pecl install apcu-5.1.28; \
    pecl install redis-6.3.0; \
    docker-php-ext-enable apcu redis; \
    rm -rf /tmp/pear

# PHP設定
RUN set -eux; \
    { \
        echo "memory_limit=256M"; \
    } > /usr/local/etc/php/conf.d/php-matomo.ini

RUN set -eux; \
    { \
        echo "opcache.memory_consumption=128"; \
        echo "opcache.interned_strings_buffer=8"; \
        echo "opcache.max_accelerated_files=4000"; \
        echo "opcache.revalidate_freq=2"; \
        echo "opcache.fast_shutdown=1"; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

# =========================
# Matomo download & verify
# =========================
RUN set -eux; \
    curl -fsSL -o /tmp/matomo.tar.gz \
        "https://builds.matomo.org/matomo-${MATOMO_VERSION}.tar.gz"; \
    curl -fsSL -o /tmp/matomo.tar.gz.asc \
        "https://builds.matomo.org/matomo-${MATOMO_VERSION}.tar.gz.asc"; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver keyserver.ubuntu.com \
        --recv-keys F529A27008477483777FC23D63BB30D0E5D2C749; \
    gpg --batch --verify /tmp/matomo.tar.gz.asc /tmp/matomo.tar.gz; \
    gpgconf --kill all; \
    rm -rf "$GNUPGHOME" /tmp/matomo.tar.gz.asc; \
    mkdir -p /usr/src/matomo; \
    tar -xzf /tmp/matomo.tar.gz -C /usr/src/; \
    rm -f /tmp/matomo.tar.gz

# =========================
# 後始末（ここで gnupg 消してOK）
# =========================
RUN set -eux; \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual apache2 > /dev/null; \
    apt-get purge -y --auto-remove \
        gnupg \
        dirmngr \
        pkg-config \
        unzip; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# DocumentRoot 作成（※ 所有権はいじらない）
RUN mkdir -p /home/matomo-data

# entrypoint
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["apache2-foreground"]
