# DockStation

A GNOME application written in Vala with GTK4 and libadwaita to manage and create Docker Compose projects.

## Features

### Manage projects

- **Project list**: add existing Compose folders or create new ones. Each project shows its live state: running, partly running, stopped or not created.
- **Services**: every service shows its state, status and published ports, with buttons to start, stop and restart it, open it in the browser and view its logs.
- **Project actions**: start (`up -d`), stop, restart, pull images, build images, remove containers (`down`), and remove containers and volumes (`down -v`, confirmation required).
- **Configuration editor**: edit `compose.yaml`, override files, `.env` and `Dockerfile`. Ctrl+S saves, and the configuration is checked with `docker compose config` after each save. The Tab key inserts spaces and new lines keep the YAML indentation.
- **Logs**: follows logs live, for all services or a single one, with optional timestamps.
- **Output**: full output of every command DockStation runs. It opens automatically when a command fails.
- **Remove from list**: forgets a project and leaves its files, containers and volumes alone.
- **Delete project**: after confirmation, removes the containers, volumes and locally built images, and moves the folder to the Trash. Each step can be turned off in the dialog. If removing the containers fails, the folder is left untouched.

### Create projects

| Template | Services | Default port | PHP versions |
| --- | --- | --- | --- |
| Blank | A minimal `compose.yaml` | – | – |
| Static Website | Nginx serving `./html` | 8080 | – |
| PostgreSQL + Adminer | PostgreSQL 17, Adminer | 8081 | – |
| PHP App | PHP + Apache serving `./src` | 8084 | 8.2 – 8.5 |
| WordPress | WordPress, MariaDB 11 | 8000 | 8.2 – 8.5 |
| Drupal | Drupal 11, MariaDB 11 | 8082 | 8.3 – 8.5 |
| Node.js App | Node 22, built from a `Dockerfile` | 3000 | – |
| Python App | Flask + Gunicorn, built from a `Dockerfile` | 5000 | – |
| Symfony | PHP, created with Composer on first start, PostgreSQL 17 | 8083 | 8.2 – 8.5 |

- Project settings such as the host port, passwords and the PHP version are written to the project's `.env`. Passwords are generated randomly.
- **PHP projects** get a generated `Dockerfile` for the chosen PHP version (8.4 by default). It installs basic tools (`curl`, `git`, `unzip`) and common PHP extensions with [install-php-extensions](https://github.com/mlocati/docker-php-extension-installer). To switch versions later, change `PHP_VERSION` in `.env` and rebuild the images.
- **Install Composer** adds Composer to PHP images. It is optional for PHP App (on by default) and WordPress (off by default). It is always on for Symfony, which needs it, and for Drupal, whose image already includes it.
- **Symfony** runs as your user, so the files it creates in `./app` belong to you. With PHP versions older than 8.4 it installs Symfony 7.4 LTS.

## Requirements

- `valac` ≥ 0.56, `meson` ≥ 1.0, `ninja`
- GTK ≥ 4.14, libadwaita ≥ 1.6, GLib ≥ 2.76
- Docker with the Compose v2 plugin (`docker compose`), usable by your user (for example, through the `docker` group)

On Debian or Ubuntu:

```sh
sudo apt install valac meson ninja-build libgtk-4-dev libadwaita-1-dev
```

## Build and run

The build directory is `build/`, which git ignores.

```sh
meson setup build
ninja -C build
./build/src/dockstation
```

Run the checks (desktop file and AppStream metadata validation):

```sh
meson test -C build
```

Install for your user, so the icon and desktop entry show up in GNOME:

```sh
meson setup build --prefix="$HOME/.local"   # or: meson configure build --prefix="$HOME/.local"
ninja -C build install
```

### Flatpak

When DockStation runs inside Flatpak, it forwards `docker` commands to the host through `flatpak-spawn --host`. A Flatpak manifest is not included yet. One would need `--talk-name=org.freedesktop.Flatpak` and access to the project folders (for example, `--filesystem=home`).

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Ctrl+N | New project |
| Ctrl+O | Add existing project |
| Ctrl+R / F5 | Refresh |
| Ctrl+S | Save the file being edited |
| Ctrl+Q | Quit |

## Where data is stored

- The project list: `~/.config/dockstation/projects.ini`.
- Everything else lives in each project's folder (`compose.yaml`, `.env`, …) and in Docker.

## Code layout

| File | Purpose |
| --- | --- |
| `src/application.vala` | `Adw.Application`, app actions and shortcuts |
| `src/window.vala` | Main window: sidebar, periodic status refresh, adding, removing and deleting projects |
| `src/project-view.vala` | Per-project page: services, editor, logs, output, project actions |
| `src/docker.vala` | Async `docker` runner (collects output or streams it line by line) |
| `src/project.vala`, `src/project-store.vala` | Project model and persistence |
| `src/templates.vala` | Project templates and the PHP `Dockerfile` generator |
| `src/new-project-dialog.vala` | New Project dialog |
| `src/service-row.vala`, `src/project-row.vala`, `src/log-view.vala` | Widgets |
| `src/utils.vala` | Helpers: port parsing, folder names, secrets |
| `data/` | Desktop entry, AppStream metadata and app icon |
| `po/` | Translations (gettext) |

## License

GPL-3.0-or-later, as declared in `meson.build`. A `LICENSE` file has not been added yet.
