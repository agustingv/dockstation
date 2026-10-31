# Change PHP_VERSION in .env and rebuild the image to switch PHP versions.
ARG PHP_VERSION={{PHP_VERSION}}
FROM php:${PHP_VERSION}-cli

# Installs PHP extensions together with the system libraries they need.
# Supported extensions: https://github.com/mlocati/docker-php-extension-installer
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

# Basic tools and PHP extensions. Add more extensions to the list as needed.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl git unzip \
 && rm -rf /var/lib/apt/lists/* \
 && install-php-extensions bcmath gd intl opcache pdo_pgsql zip
{{COMPOSER_INSTALL}}
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

# The container runs as the host user, which has no home directory in the image.
ENV HOME=/tmp
WORKDIR /app
EXPOSE 8000
ENTRYPOINT ["docker-entrypoint"]
