FROM php:8.4-apache

ARG MATOMO_VERSION=5.6.2
ARG PHP_MEMORY_LIMIT=256M

ENV MATOMO_VERSION=${MATOMO_VERSION} \
    PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT} \
    MATOMO_DATA=/home/matomo-data \
    MATOMO_WEBROOT=/home/matomo-data/www

RUN set -ex; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libfreetype-dev \
        libjpeg-dev \
        libldap2-dev \
        libpng-dev \
        libzip-dev \
        procps \
        dirmngr \
        gnupg \
        ca-certificates \
        curl \
    ; \
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
    pecl install APCu-5.1.28; \
    pecl install redis-6.3.0; \
    docker-php-ext-enable apcu redis; \
    rm -r /tmp/pear; \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); print so }' \
        | sort -u \
        | xargs -rt dpkg-query --search \
        | awk 'sub(":$", "", $1) { print $1 }' \
        | sort -u \
        | xargs -rt apt-mark manual; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    apt-get dist-clean; \
    rm -rf /var/lib/apt/lists/*

RUN { \
      echo "memory_limit=${PHP_MEMORY_LIMIT}"; \
    } > /usr/local/etc/php/conf.d/php-matomo.ini

# opcache recommended
RUN { \
        echo 'opcache.memory_consumption=128'; \
        echo 'opcache.interned_strings_buffer=8'; \
        echo 'opcache.max_accelerated_files=4000'; \
        echo 'opcache.revalidate_freq=2'; \
        echo 'opcache.fast_shutdown=1'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

# download & verify Matomo
RUN set -ex; \
    curl -fsSL -o /tmp/matomo.tar.gz "https://builds.matomo.org/matomo-${MATOMO_VERSION}.tar.gz"; \
    curl -fsSL -o /tmp/matomo.tar.gz.asc "https://builds.matomo.org/matomo-${MATOMO_VERSION}.tar.gz.asc"; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys F529A27008477483777FC23D63BB30D0E5D2C749; \
    gpg --batch --verify /tmp/matomo.tar.gz.asc /tmp/matomo.tar.gz; \
    gpgconf --kill all; \
    rm -rf "$GNUPGHOME" /tmp/matomo.tar.gz.asc; \
    mkdir -p /usr/src/matomo; \
    tar -xzf /tmp/matomo.tar.gz -C /usr/src/; \
    rm -f /tmp/matomo.tar.gz

# Apache docroot -> /home/matomo-data/www
RUN set -ex; \
    sed -ri 's!/var/www/html!${MATOMO_WEBROOT}!g' /etc/apache2/sites-available/000-default.conf; \
    sed -ri 's!/var/www/!${MATOMO_DATA}/!g' /etc/apache2/apache2.conf; \
    a2enmod rewrite headers expires; \
    # AllowOverride は不要（htaccess削除要件）なので None のままでもOK。Matomo は動く。
    true

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

VOLUME ["/home/matomo-data"]

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["apache2-foreground"]
