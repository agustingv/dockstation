# Change PHP_VERSION in .env and rebuild the image to switch PHP versions.
ARG PHP_VERSION={{PHP_VERSION}}
FROM php:${PHP_VERSION}-apache

# Installs PHP extensions together with the system libraries they need.
# Supported extensions: https://github.com/mlocati/docker-php-extension-installer
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

# Basic tools and PHP extensions. Add more extensions to the list as needed.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl git unzip \
 && rm -rf /var/lib/apt/lists/* \
 && install-php-extensions bcmath gd intl opcache pdo_mysql pdo_pgsql zip
{{COMPOSER_INSTALL}}
# Pretty URLs through .htaccess
RUN a2enmod rewrite
