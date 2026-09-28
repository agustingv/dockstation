namespace DockStation {
    /*
     * A project skeleton. File contents may contain {{NAME}}, {{NAME_HTML}},
     * {{SLUG}}, {{PORT}}, {{PASSWORD}}, {{UID}}, {{GID}}, {{PHP_VERSION}} and
     * {{COMPOSER_INSTALL}} placeholders.
     */
    public enum ComposerSupport {
        NONE,       // Not a PHP template
        OPTIONAL,   // The user chooses whether the image gets Composer
        INCLUDED,   // The base image already ships Composer
        REQUIRED,   // The template cannot work without Composer
    }

    public class Template : Object {
        public string name { get; construct; }
        public string description { get; construct; }
        public int default_port { get; construct; }

        /* PHP versions the template supports, oldest first. Empty if it does not use PHP. */
        public string[] php_versions { get; private set; default = {}; }
        public string default_php_version { get; private set; default = ""; }
        public string php_note { get; private set; default = ""; }
        public ComposerSupport composer { get; private set; default = ComposerSupport.NONE; }
        public bool composer_default { get; private set; default = false; }

        private string[] paths = {};
        private string[] contents = {};

        public bool uses_port {
            get { return default_port > 0; }
        }

        public bool uses_php {
            get { return php_versions.length > 0; }
        }

        public Template (string name, string description, int default_port = 0) {
            Object (name: name, description: description, default_port: default_port);
        }

        public Template with_php (string[] versions, string default_version, string note) {
            php_versions = versions;
            default_php_version = default_version;
            php_note = note;
            return this;
        }

        public Template with_composer (ComposerSupport support, bool default_enabled = true) {
            composer = support;
            composer_default = support != ComposerSupport.OPTIONAL || default_enabled;
            return this;
        }

        public Template add_file (string path, string content) {
            paths += path;
            contents += content;
            return this;
        }

        public void write_to (File dir, HashTable<string, string> vars) throws Error {
            ensure_directory (dir);
            for (int i = 0; i < paths.length; i++) {
                var file = dir.resolve_relative_path (paths[i]);
                ensure_directory (file.get_parent ());
                var text = substitute (contents[i], vars);
                file.replace_contents (text.data, null, false, FileCreateFlags.NONE, null);
            }
        }

        private static void ensure_directory (File dir) throws Error {
            try {
                dir.make_directory_with_parents ();
            } catch (IOError.EXISTS e) {
            }
        }

        private static string substitute (string text, HashTable<string, string> vars) {
            var result = text;
            vars.foreach ((key, value) => {
                result = result.replace ("{{" + key + "}}", value);
            });
            return result;
        }
    }

    namespace Templates {
        private const string ENV_PORT = "HOST_PORT={{PORT}}\n";
        private const string ENV_PHP = "PHP_VERSION={{PHP_VERSION}}\n";
        private const string DEFAULT_PHP = "8.4";

        /* Replaces {{COMPOSER_INSTALL}} in PHP Dockerfiles when Composer is enabled. */
        public const string COMPOSER_DOCKERFILE = """
# Composer, to manage PHP dependencies
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
ENV COMPOSER_HOME=/tmp/composer COMPOSER_ALLOW_SUPERUSER=1
""";

        /*
         * Dockerfile for a PHP image: pinned PHP version, basic tools, the given
         * PHP extensions and, optionally, Composer. `base_image` may use ${PHP_VERSION}.
         */
        private string php_dockerfile (string base_image, string extensions, string tail = "") {
            return """# Change PHP_VERSION in .env and rebuild the image to switch PHP versions.
ARG PHP_VERSION={{PHP_VERSION}}
FROM """ + base_image + """

# Installs PHP extensions together with the system libraries they need.
# Supported extensions: https://github.com/mlocati/docker-php-extension-installer
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

# Basic tools and PHP extensions. Add more extensions to the list as needed.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl git unzip \
 && rm -rf /var/lib/apt/lists/* \
 && install-php-extensions """ + extensions + "\n{{COMPOSER_INSTALL}}" + tail;
        }

        public Template blank () {
            return new Template (_("Blank"), _("A minimal compose file to start from scratch"))
                .add_file ("compose.yaml", """name: {{SLUG}}

services:
  app:
    image: alpine:latest
    command: ["sleep", "infinity"]
    restart: unless-stopped
""");
        }

        public Template[] all () {
            return {
                blank (),

                new Template (_("Static Website"), _("Nginx serving the files in ./html"), 8080)
                    .add_file ("compose.yaml", """name: {{SLUG}}

services:
  web:
    image: nginx:alpine
    ports:
      - "${HOST_PORT}:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
    restart: unless-stopped
""")
                    .add_file (".env", ENV_PORT)
                    .add_file ("html/index.html", """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{NAME_HTML}}</title>
</head>
<body>
  <h1>{{NAME_HTML}}</h1>
  <p>Served by Nginx running in Docker Compose.</p>
</body>
</html>
"""),

                new Template (_("PostgreSQL + Adminer"), _("A PostgreSQL database with a web administration UI"), 8081)
                    .add_file ("compose.yaml", """name: {{SLUG}}

services:
  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  adminer:
    image: adminer:latest
    ports:
      - "${HOST_PORT}:8080"
    environment:
      ADMINER_DEFAULT_SERVER: db
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

volumes:
  db-data:
""")
                    .add_file (".env", ENV_PORT + """POSTGRES_USER={{SLUG}}
POSTGRES_PASSWORD={{PASSWORD}}
POSTGRES_DB={{SLUG}}
"""),

                new Template (_("PHP App"), _("PHP with Apache, serving the files in ./src"), 8084)
                    .with_php ({ "8.2", "8.3", "8.4", "8.5" }, DEFAULT_PHP, _("The PHP version of the image"))
                    .with_composer (ComposerSupport.OPTIONAL, true)
                    .add_file ("compose.yaml", """name: {{SLUG}}

services:
  app:
    build:
      context: .
      args:
        PHP_VERSION: ${PHP_VERSION}
    ports:
      - "${HOST_PORT}:80"
    volumes:
      - ./src:/var/www/html
    restart: unless-stopped
""")
                    .add_file (".env", ENV_PORT + ENV_PHP)
                    .add_file ("Dockerfile", php_dockerfile ("php:${PHP_VERSION}-apache",
                                                             "bcmath gd intl opcache pdo_mysql pdo_pgsql zip",
                                                             "\n# Pretty URLs through .htaccess\nRUN a2enmod rewrite\n"))
                    .add_file (".dockerignore", "src\n")
                    .add_file ("src/index.php", """<?php declare(strict_types=1); ?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{NAME_HTML}}</title>
</head>
<body>
  <h1>{{NAME_HTML}}</h1>
  <p>Running PHP <?= PHP_VERSION ?> in Docker Compose.</p>
  <p>Extensions: <?= htmlspecialchars(implode(', ', get_loaded_extensions())) ?></p>
</body>
</html>
""")
                    .add_file ("README.md", """# {{NAME}}

The code in `./src` is served by Apache on http://localhost:{{PORT}}.

- PHP version and extensions are defined in the `Dockerfile`; the version is
  `PHP_VERSION` in `.env`. Rebuild the image after changing them.
- If Composer is installed in the image, run it as your user so the files in
  `./src` stay yours:

  ```sh
  docker compose exec --user "$(id -u):$(id -g)" app composer require vendor/package
  ```
"""),

                new Template (_("WordPress"), _("WordPress with a MariaDB database"), 8000)
                    .with_php ({ "8.2", "8.3", "8.4", "8.5" }, DEFAULT_PHP,
                               _("Some plugins may not support the newest PHP yet"))
                    .with_composer (ComposerSupport.OPTIONAL, false)
                    .add_file ("compose.yaml", """name: {{SLUG}}

services:
  db:
    image: mariadb:11
    environment:
      MARIADB_DATABASE: wordpress
      MARIADB_USER: wordpress
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_RANDOM_ROOT_PASSWORD: "1"
    volumes:
      - db-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  wordpress:
    build:
      context: .
      args:
        PHP_VERSION: ${PHP_VERSION}
    ports:
      - "${HOST_PORT}:80"
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: ${DB_PASSWORD}
      WORDPRESS_DB_NAME: wordpress
    volumes:
      - wp-data:/var/www/html
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

volumes:
  db-data:
  wp-data:
""")
                    .add_file (".env", ENV_PORT + ENV_PHP + "DB_PASSWORD={{PASSWORD}}\n")
                    .add_file ("Dockerfile", php_dockerfile ("wordpress:php${PHP_VERSION}-apache",
                                                             "bcmath exif gd imagick intl mysqli opcache zip")),

                new Template (_("Drupal"), _("Drupal 11 with a MariaDB database"), 8082)
                    .with_php ({ "8.3", "8.4", "8.5" }, DEFAULT_PHP,
                               _("Drupal 11 requires PHP 8.3 or newer"))
                    .with_composer (ComposerSupport.INCLUDED)
                    .add_file ("compose.yaml", """name: {{SLUG}}

services:
  drupal:
    build:
      context: .
      args:
        PHP_VERSION: ${PHP_VERSION}
    ports:
      - "${HOST_PORT}:80"
    volumes:
      # Named volumes are initialised with the image content on first start.
      - drupal-modules:/opt/drupal/web/modules
      - drupal-profiles:/opt/drupal/web/profiles
      - drupal-themes:/opt/drupal/web/themes
      - drupal-sites:/opt/drupal/web/sites
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

  db:
    image: mariadb:11
    environment:
      MARIADB_DATABASE: drupal
      MARIADB_USER: drupal
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_RANDOM_ROOT_PASSWORD: "1"
    volumes:
      - db-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  drupal-modules:
  drupal-profiles:
  drupal-themes:
  drupal-sites:
  db-data:
""")
                    .add_file (".env", ENV_PORT + ENV_PHP + "DB_PASSWORD={{PASSWORD}}\n")
                    .add_file ("Dockerfile", php_dockerfile ("drupal:11-php${PHP_VERSION}-apache",
                                                             "apcu bcmath gd intl opcache pdo_mysql pdo_pgsql zip",
                                                             "\n# Composer is already included in the official Drupal image.\n"))
                    .add_file ("README.md", """# {{NAME}}

Open http://localhost:{{PORT}} and follow the Drupal installer.

On the *Set up database* step choose **MySQL, MariaDB, Percona Server, or equivalent** and use:

| Setting | Value |
| --- | --- |
| Database name | `drupal` |
| Database username | `drupal` |
| Database password | `DB_PASSWORD` in `.env` |
| Host (Advanced options) | `db` |
"""),

                new Template (_("Node.js App"), _("A Node.js HTTP server built from a Dockerfile"), 3000)
                    .add_file ("compose.yaml", """name: {{SLUG}}

services:
  app:
    build: .
    ports:
      - "${HOST_PORT}:3000"
    environment:
      NODE_ENV: production
    restart: unless-stopped
""")
                    .add_file (".env", ENV_PORT)
                    .add_file ("Dockerfile", """FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev
COPY . .
EXPOSE 3000
CMD ["node", "index.js"]
""")
                    .add_file (".dockerignore", "node_modules\nnpm-debug.log\n")
                    .add_file ("package.json", """{
  "name": "{{SLUG}}",
  "version": "1.0.0",
  "private": true,
  "main": "index.js",
  "scripts": {
    "start": "node index.js"
  }
}
""")
                    .add_file ("index.js", """const http = require("node:http");

const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
  res.end("Hello from {{SLUG}}!\n");
});

server.listen(3000, () => console.log("Listening on port 3000"));
"""),

                new Template (_("Python App"), _("A Flask application served by Gunicorn"), 5000)
                    .add_file ("compose.yaml", """name: {{SLUG}}

services:
  app:
    build: .
    ports:
      - "${HOST_PORT}:5000"
    restart: unless-stopped
""")
                    .add_file (".env", ENV_PORT)
                    .add_file ("Dockerfile", """FROM python:3.13-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app"]
""")
                    .add_file (".dockerignore", "__pycache__\n*.pyc\n.venv\n")
                    .add_file ("requirements.txt", "flask\ngunicorn\n")
                    .add_file ("app.py", """from flask import Flask

app = Flask(__name__)


@app.route("/")
def index():
    return "Hello from {{SLUG}}!"
"""),

                new Template (_("Symfony"), _("A Symfony app with PostgreSQL, created on first start"), 8083)
                    .with_php ({ "8.2", "8.3", "8.4", "8.5" }, DEFAULT_PHP,
                               _("Symfony 8 requires PHP 8.4 or newer; older versions get Symfony 7.4 LTS"))
                    .with_composer (ComposerSupport.REQUIRED)
                    .add_file ("compose.yaml", """name: {{SLUG}}

services:
  app:
    build:
      context: .
      args:
        PHP_VERSION: ${PHP_VERSION}
    # Run as your user so files created in ./app belong to you.
    user: "${UID}:${GID}"
    ports:
      - "${HOST_PORT}:8000"
    environment:
      HOST_PORT: ${HOST_PORT}
      DATABASE_URL: postgresql://app:${POSTGRES_PASSWORD}@database:5432/app?serverVersion=17&charset=utf8
    volumes:
      - ./app:/app
    depends_on:
      database:
        condition: service_healthy
    restart: unless-stopped

  database:
    image: postgres:17-alpine
    environment:
      POSTGRES_DB: app
      POSTGRES_USER: app
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - database-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d app"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  database-data:
""")
                    .add_file (".env", ENV_PORT + ENV_PHP + """UID={{UID}}
GID={{GID}}
POSTGRES_PASSWORD={{PASSWORD}}
""")
                    .add_file ("Dockerfile", php_dockerfile ("php:${PHP_VERSION}-cli",
                                                             "bcmath gd intl opcache pdo_pgsql zip",
                                                             """
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

# The container runs as the host user, which has no home directory in the image.
ENV HOME=/tmp
WORKDIR /app
EXPOSE 8000
ENTRYPOINT ["docker-entrypoint"]
"""))
                    .add_file ("docker-entrypoint.sh", """#!/bin/sh
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
""")
                    .add_file (".dockerignore", "app\n")
                    .add_file ("app/.gitkeep", "")
                    .add_file ("README.md", """# {{NAME}}

The Symfony application lives in `./app`. On the first start the `app`
container creates it with `composer create-project symfony/skeleton`;
follow the progress in the *Logs* tab.

Run Symfony commands inside the container:

```sh
docker compose exec app php bin/console about
docker compose exec app composer require webapp
```

The app is served on http://localhost:{{PORT}} by PHP's built-in web server,
and `DATABASE_URL` already points to the `database` service.
"""),
            };
        }
    }
}
