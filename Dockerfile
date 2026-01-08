# syntax=docker/dockerfile:1.7
FROM php:8.4-apache

ARG MATOMO_VERSION=5.6.1
ENV MATOMO_VERSION=${MATOMO_VERSION}

# Apache 設定（必要なら調整）
RUN set -eux; \
    a2enmod rewrite headers expires remoteip

# ---- PHP extensions build deps & runtime deps ----
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      dpkg-dev \
      file \
      g++ \
      gcc \
      make \
      pkg-config \
      re2c \
      xz-utils \
      zlib1g-dev \
      libzip-dev \
      libpng-dev \
      libjpeg62-turbo-dev \
      libfreetype6-dev \
      libldap2-dev \
      libssl-dev \
      libzstd-dev \
      liblzma-dev \
      libonig-dev \
      libsasl2-dev \
      libicu-dev \
      gnupg \
      dirmngr \
    ; \
    rm -rf /var/lib/apt/lists/*

# ---- PHP core extensions ----
RUN set -eux; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
      bcmath \
      gd \
      ldap \
      mysqli \
      pdo_mysql \
      zip \
      opcache

# ---- PECL extensions: apcu, redis ----
RUN set -eux; \
    pecl install apcu-5.1.28; \
    pecl install redis-6.3.0; \
    docker-php-ext-enable apcu redis

# ---- PHP ini tweaks ----
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

# ---- download & verify Matomo (GPG) ----
RUN set -eux; \
    curl -fsSL -o /tmp/matomo.tar.gz "https://builds.matomo.org/matomo-${MATOMO_VERSION}.tar.gz"; \
    curl -fsSL -o /tmp/matomo.tar.gz.asc "https://builds.matomo.org/matomo-${MATOMO_VERSION}.tar.gz.asc"; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys F529A27008477483777FC23D63BB30D0E5D2C749; \
    gpg --batch --verify /tmp/matomo.tar.gz.asc /tmp/matomo.tar.gz; \
    gpgconf --kill all; \
    rm -rf "$GNUPGHOME" /tmp/matomo.tar.gz.asc; \
    mkdir -p /usr/src; \
    tar -xzf /tmp/matomo.tar.gz -C /usr/src/; \
    rm -f /tmp/matomo.tar.gz; \
    test -f /usr/src/matomo/matomo.php; \
    chown -R www-data:www-data /usr/src/matomo

# ---- entrypoint ----
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN set -eux; \
    chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["apache2-foreground"]

# ---- cleanup build deps (optional) ----
# ここで消してOK（Matomo取得・検証はすでに完了しているため）
RUN set -eux; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false \
      dpkg-dev \
      file \
      g++ \
      gcc \
      make \
      pkg-config \
      re2c \
      xz-utils \
      zlib1g-dev \
      libzip-dev \
      libpng-dev \
      libjpeg62-turbo-dev \
      libfreetype6-dev \
      libldap2-dev \
      libssl-dev \
      libzstd-dev \
      liblzma-dev \
      libonig-dev \
      libsasl2-dev \
      libicu-dev \
      gnupg \
      dirmngr \
    ; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
