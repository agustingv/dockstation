# DockStation

A GNOME application (Vala + GTK4 + libadwaita) to manage and create Docker Compose projects.

## Features

- **Project list**: add existing Compose folders or create new ones. Each project shows its live state (running / partial / stopped / not created).
- **Services**: every service shows its state, status and published ports, with buttons to start, stop, restart, open it in the browser and view its logs.
- **Project actions**: start (`up -d`), stop, restart, pull, build, remove containers (`down`), and remove containers and volumes (`down -v`, asks for confirmation first).
- **Configuration editor**: edit `compose.yaml`, override files, `.env` and `Dockerfile`. Ctrl+S saves, and the configuration is checked with `docker compose config` after each save. The Tab key inserts spaces and new lines keep the YAML indentation.
- **Logs**: follows logs live, for all services or just one, with optional timestamps.
- **Output**: full output of every command DockStation runs.
- **New project templates**: Blank, Static Website (Nginx), PostgreSQL + Adminer, PHP App (Apache), WordPress + MariaDB, Drupal 11 + MariaDB, Node.js, Python (Flask + Gunicorn), Symfony (PostgreSQL). Passwords are generated randomly and written to `.env`.
- **PHP projects**: you choose the PHP version, stored as `PHP_VERSION` in `.env`. DockStation generates a `Dockerfile` for that version with basic tools (`curl`, `git`, `unzip`) and common PHP extensions, installed with [install-php-extensions](https://github.com/mlocati/docker-php-extension-installer). An **Install Composer** option adds Composer to the image. It is always on for Symfony, which needs it, and for Drupal, whose image already includes it.

The project list is stored in `~/.config/dockstation/projects.ini`.

## Requirements

- `valac` ≥ 0.56, `meson`, `ninja`
- GTK ≥ 4.14, libadwaita ≥ 1.6
- Docker with the Compose v2 plugin (`docker compose`), usable by your user

## Build and run

```sh
meson setup _build
ninja -C _build
./_build/src/dockstation
```

Install (so the icon and desktop file are picked up):

```sh
meson setup _build --prefix="$HOME/.local"
ninja -C _build install
```

### Flatpak

```sh
flatpak-builder --user --install --force-clean .flatpak build-aux/flatpak/es.agustin_garcia.DockStation.json
flatpak run es.agustin_garcia.DockStation
```

Inside the sandbox, `docker` runs on the host through `flatpak-spawn --host`.

## Code layout

| File | Purpose |
| --- | --- |
| `src/application.vala` | `Adw.Application`, app actions and shortcuts |
| `src/window.vala` | Main window: sidebar, periodic status refresh, add/remove projects |
| `src/project-view.vala` | Per-project page: services, editor, logs, output |
| `src/docker.vala` | Async `docker` runner (collect output or stream it line by line) |
| `src/project.vala`, `src/project-store.vala` | Project model and persistence |
| `src/templates.vala`, `src/new-project-dialog.vala` | Project templates and the New Project dialog |
| `src/service-row.vala`, `src/project-row.vala`, `src/log-view.vala` | Widgets |
