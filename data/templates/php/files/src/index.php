<?php declare(strict_types=1); ?>
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
