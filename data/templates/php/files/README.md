# {{NAME}}

The code in `./src` is served by Apache on http://localhost:{{PORT}}.

- PHP version and extensions are defined in the `Dockerfile`; the version is
  `PHP_VERSION` in `.env`. Rebuild the image after changing them.
- If Composer is installed in the image, run it as your user so the files in
  `./src` stay yours:

  ```sh
  docker compose exec --user "$(id -u):$(id -g)" app composer require vendor/package
  ```
