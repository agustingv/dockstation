# {{NAME}}

Open http://localhost:{{PORT}} and follow the Drupal installer.

On the *Set up database* step choose **MySQL, MariaDB, Percona Server, or equivalent** and use:

| Setting | Value |
| --- | --- |
| Database name | `drupal` |
| Database username | `drupal` |
| Database password | `DB_PASSWORD` in `.env` |
| Host (Advanced options) | `db` |
