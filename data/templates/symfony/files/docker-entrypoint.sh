#!/bin/sh
set -e

if [ ! -f composer.json ]; then
    echo "Creating a new Symfony project in ./app (this takes a minute)…"
    composer create-project symfony/skeleton /tmp/skeleton --no-interaction
    cp -a /tmp/skeleton/. .
    rm -rf /tmp/skeleton
elif [ ! -d vendor ]; then
    composer install --no-interaction
fi

echo "Symfony is available at http://localhost:${HOST_PORT:-8000}"
exec php -S 0.0.0.0:8000 -t public
