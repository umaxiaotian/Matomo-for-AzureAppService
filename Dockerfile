FROM php:8.4-apache

ARG MATOMO_VERSION
ARG PHP_MEMORY_LIMIT

ENV MATOMO_VERSION=${MATOMO_VERSION} \
    PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT}

# ==== PHP拡張 & SSH のインストール ====
RUN set -ex; \
    apt-get update; \
    apt-get -y upgrade; \
    apt-get install -y --no-install-recommends \
      libfreetype-dev \
      libjpeg-dev \
      libldap2-dev \
      libpng-dev \
      libzip-dev \
      procps \
      curl \
      openssh-server \
      sysstat \
    ; \
    rm -rf /var/lib/apt/lists/* \
    sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat; \
    \
    debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-configure ldap --with-libdir="lib/$debMultiarch"; \
    docker-php-ext-install -j "$(nproc)" \
        gd \
        bcmath \
        ldap \
        mysqli \
        pdo_mysql \
        zip \
    ; \
    \
    pecl install APCu-5.1.27; \
    pecl install redis-6.3.0; \
    docker-php-ext-enable apcu redis; \
    rm -r /tmp/pear; \
    \
    echo "root:Docker!" | chpasswd; \
    mkdir -p /var/run/sshd; \
    rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub; \
    \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    apt-get dist-clean

RUN a2enmod rewrite

RUN echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf \
    && a2enconf servername

RUN { \
        echo 'opcache.memory_consumption=128'; \
        echo 'opcache.interned_strings_buffer=8'; \
        echo 'opcache.max_accelerated_files=4000'; \
        echo 'opcache.revalidate_freq=2'; \
        echo 'opcache.fast_shutdown=1'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

# ==== Matomo 本体を取得（このステップ内で gnupg/dirmngr を一時インストール） ====
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends gnupg dirmngr; \
    \
    curl -fsSL -o matomo.tar.gz \
        "https://builds.matomo.org/matomo-${MATOMO_VERSION}.tar.gz"; \
    curl -fsSL -o matomo.tar.gz.asc \
        "https://builds.matomo.org/matomo-${MATOMO_VERSION}.tar.gz.asc"; \
    \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys F529A27008477483777FC23D63BB30D0E5D2C749; \
    gpg --batch --verify matomo.tar.gz.asc matomo.tar.gz; \
    gpgconf --kill all; \
    rm -rf "$GNUPGHOME" matomo.tar.gz.asc; \
    \
    tar -xzf matomo.tar.gz -C /usr/src/; \
    rm matomo.tar.gz; \
    \
    apt-get purge -y --auto-remove gnupg dirmngr; \
    apt-get dist-clean

# ==== Matomo 用 PHP 設定 ====
COPY php.ini /usr/local/etc/php/conf.d/php-matomo.ini

# ==== (追加) plugins をイメージにバンドル ====
COPY plugins/ /usr/src/matomo/plugins/
RUN chown -R www-data:www-data /usr/src/matomo/plugins || true

# ==== SSH サーバ設定（Port 2222 など） ====
COPY sshd_config /etc/ssh/sshd_config

# ==== エントリポイント ====
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

WORKDIR /var/www/html

VOLUME /home

EXPOSE 80 2222

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["apache2-foreground"]