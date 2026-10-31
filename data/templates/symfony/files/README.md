# {{NAME}}

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
