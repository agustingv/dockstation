# DockStation

A GNOME application written in Vala with GTK4 and libadwaita to manage and create Docker Compose projects.

## Features

### Manage projects

- **Project list**: add existing Compose folders or create new ones. Each project shows its live state: running, partly running, stopped or not created.
- **Services**: every service shows its state, status and published ports, with buttons to start, stop and restart it, open it in the browser and view its logs.
- **Traefik**: web containers routed by Traefik show their address (for example `blog.localhost`), read from the container's `traefik.http.routers.*` labels. Their **Open in Browser** button opens that address, using `https` when the router has TLS or uses the `websecure` entrypoint. When a service has several addresses (more hosts, or a Traefik route plus a published port), the button offers a list, and each entry names the router it comes from. Routes defined only in Traefik's own configuration files are not shown.
- **Add a service**: the **+** button next to *Services* adds a service to an existing project: databases (PostgreSQL, MariaDB, MySQL, MongoDB, Redis), web servers (Nginx, Apache, Tomcat, and an Nginx reverse proxy for another service), Adminer or Mailpit. Choose the service name, the image version, a host port (only reachable at `localhost`) and, depending on the service, a folder to serve or the service to forward to. The service is written to its own `compose.<service>.yaml`, and DockStation adds it to the `include:` list of the compose file; nothing else in that file changes. Generated passwords go to `.env`, and a comment at the top of the new file explains how to use the service. Web servers get an example page when their folder is new or empty; existing files are never overwritten. The result is checked with `docker compose config` before the compose file is changed, and every change is undone if the check fails. Services added this way have a **Remove** button: after confirmation, DockStation removes the container, the service's file, its `include:` line and its `.env` settings, and can also delete its data volume. It refuses if the rest of the project still depends on the service, keeps `.env` variables that other services still use, and never deletes the files in the service's folders. You can also [write your own services](#custom-services). Needs Docker Compose 2.20 or newer.
- **Project actions**: start (`up -d`), stop, restart, pull images, build images, remove containers (`down`), and remove containers and volumes (`down -v`, confirmation required).
- **Recreate containers**: creates every container again from its image (`up -d --force-recreate --remove-orphans`, confirmation required). It fixes what Start and Restart cannot, because Docker only sets some things when a container is created: its DNS configuration, network attachments and hostname. Data in volumes and project folders is kept; changes made inside the containers are lost. Containers of services that no longer exist are removed.
- **Reset a database**: database services that run init scripts from `/docker-entrypoint-initdb.d` get a **Reset Database** button. This covers the official PostgreSQL, MySQL/MariaDB and MongoDB images, with the scripts mounted as a folder or as single files. After confirmation, DockStation stops and removes the container, empties its data (the volume or the host folder), and starts it again. The image's own entrypoint then re-runs every init script (`.sql`, `.sql.gz`, `.sh`, …) with the same settings as the first time, and the Logs tab shows the progress. All existing data is deleted, and the dialog lists the scripts that will run. Folders that clearly hold more than the database (your home folder, the project folder, or any folder containing them) are never emptied.
- **Configuration editor**: edit the project's files, grouped in two sections:
  - **Compose**: `compose.yaml`, override files, the files of added services and `.env`. The configuration is checked with `docker compose config` after each save. **Validate** checks the text in the editor, unsaved changes included: Compose reads a temporary copy placed next to the file (removed right after), so `include` and `extends` paths still resolve.
  - **Dockerfiles**: every `Dockerfile`, `Dockerfile.*`, `*.Dockerfile` and `Containerfile` in the project, found by searching up to four folders deep. Dependency and cache folders (`node_modules`, `vendor`, `.git`, …) and symlinks are skipped. Refresh (Ctrl+R) searches again.
  
  The editor highlights YAML, Dockerfile and `.env` syntax, shows line numbers and makes tab characters visible. Ctrl+S saves. The Tab key inserts spaces (Shift+Tab removes them), new lines keep the indentation, and in YAML they add a level after `key:`. If another program changed the file since it was opened, saving asks whether to overwrite it or reload it.
- **Logs**: follows logs live, for all services or a single one, with optional timestamps.
- **Output**: full output of every command DockStation runs. It opens automatically when a command fails.
- **Remove from list**: forgets a project and leaves its files, containers and volumes alone.
- **Delete project**: after confirmation, removes the containers, volumes and locally built images, and moves the folder to the Trash. Each step can be turned off in the dialog. If removing the containers fails, the folder is left untouched.

### Docker Resources

The optional **Docker Resources** entry at the bottom of the sidebar, below the projects, shows everything Docker stores and the disk space it takes. It only loads when you click it, never at startup. To hide or show the entry, use **Show Docker Resources** in the main menu. The choice is saved in `~/.config/dockstation/settings.ini`.

The page has three tabs:

- **Containers**: the space each container has written, with its state and image.
- **Images**: size, how much is not shared with other images, when it was created and how many containers use it.
- **Volumes**: size and whether any container uses it.

Each tab starts with Docker's totals: total size, how many are in use, and how much is reclaimable. Below, items are grouped by Compose project, largest first:

- Projects in your list show their DockStation name and an **Open** button (→).
- Images used by more than one project go in **Shared by Several Projects**, and images nothing uses go in **Unused Images**.
- Anything not created by Compose goes in **Not Part of a Compose Project**.

**Free up disk space.** Every deletion asks for confirmation first and says how much space it frees.

| What | Where | Docker command |
| --- | --- | --- |
| One stopped container | Trash button on the container | `docker container rm` |
| One image no container uses | Trash button on the image | `docker image rm` |
| One volume no container uses | Trash button on the volume | `docker volume rm` |
| All stopped containers | **Remove Stopped…** (Containers tab) | `docker container prune` |
| All images no container uses | **Remove Unused…** (Images tab) | `docker image prune --all` |
| All volumes no container uses | **Delete Unused…** (Volumes tab) | `docker volume prune --all` |
| The build cache | Trash button on **Build Cache** (Images tab) | `docker builder prune --all` |

Running containers, and images or volumes that a container uses (even a stopped one), cannot be deleted from here. Deleting a volume permanently deletes its data, such as databases, and the dialog says so.

Search (or just start typing) filters by name, image or project. Measuring sizes can take a few seconds, so the page refreshes only when opened or when you press Refresh (Ctrl+R).

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
- GTK ≥ 4.14, libadwaita ≥ 1.6, GtkSourceView ≥ 5.10, GLib ≥ 2.76
- Docker with the Compose v2 plugin (`docker compose`), usable by your user (for example, through the `docker` group)

On Debian or Ubuntu:

```sh
sudo apt install valac meson ninja-build libgtk-4-dev libadwaita-1-dev libgtksourceview-5-dev
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

## Flatpak

The Flatpak manifest is [`es.agustin_garcia.DockStation.json`](es.agustin_garcia.DockStation.json). It builds DockStation with the GNOME 51 runtime, which includes GTK 4.24, libadwaita 1.10 and the Vala compiler.

### 1. Install the tools

Install `flatpak` and `flatpak-builder`, then add Flathub, where the GNOME runtime comes from.

```sh
sudo apt install flatpak flatpak-builder        # Debian / Ubuntu
sudo dnf install flatpak flatpak-builder        # Fedora

flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

Docker also has to be installed on the host and usable by your user, with no `sudo` needed. Check with:

```sh
docker compose version
docker ps
```

### 2. Build and install

From the project folder:

```sh
flatpak-builder --user --install --force-clean --install-deps-from=flathub .flatpak/build es.agustin_garcia.DockStation.json
```

- `--user` installs DockStation for your user only, with no administrator password.
- `--install-deps-from=flathub` downloads the GNOME 51 runtime and SDK the first time. The runtime alone is about 420 MB to download and 1.1 GB installed, and the SDK adds more. Later builds reuse them.
- The build folders `.flatpak/` and `.flatpak-builder/` are ignored by git.

### 3. Run

Open **DockStation** from Activities, or run:

```sh
flatpak run es.agustin_garcia.DockStation
```

### Update after changing the code

Run the same command again. The installed Flatpak does not change until you rebuild it.

```sh
flatpak-builder --user --install --force-clean .flatpak/build es.agustin_garcia.DockStation.json
```

### Share it as a single file

Create a bundle that other people can install without building:

```sh
flatpak-builder --user --force-clean --repo=repo .flatpak/build es.agustin_garcia.DockStation.json
flatpak build-bundle repo dockstation.flatpak es.agustin_garcia.DockStation \
    --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo
```

To install the bundle, run the command below. The GNOME runtime is downloaded from Flathub if it is missing. The `repo/` folder and `*.flatpak` files are ignored by git.

```sh
flatpak install --user dockstation.flatpak
```

### Uninstall

```sh
flatpak uninstall --user es.agustin_garcia.DockStation
flatpak uninstall --user --unused                  # also removes runtimes no other app uses
rm -rf ~/.var/app/es.agustin_garcia.DockStation    # optional: the Flatpak's project list
```

### How the sandbox affects DockStation

| Permission | Why |
| --- | --- |
| `--talk-name=org.freedesktop.Flatpak` | Runs `docker` on the host through `flatpak-spawn --host`. The sandbox therefore does not limit what DockStation can run on the host. |
| `--filesystem=home` | Reads and edits projects in your home folder and creates new ones there. |
| `--socket=wayland`, `--socket=fallback-x11`, `--device=dri`, `--share=ipc` | Display and graphics |

- **Projects outside your home folder** are not accessible. Grant access to another folder with:

  ```sh
  flatpak override --user --filesystem=/srv/projects es.agustin_garcia.DockStation
  ```

- **Separate project list**: the Flatpak stores its list in `~/.var/app/es.agustin_garcia.DockStation/config/dockstation/projects.ini`, not in `~/.config/dockstation/`. To reuse the projects from a native build, copy the file:

  ```sh
  mkdir -p ~/.var/app/es.agustin_garcia.DockStation/config/dockstation
  cp ~/.config/dockstation/projects.ini ~/.var/app/es.agustin_garcia.DockStation/config/dockstation/
  ```

### Troubleshooting

- **"Docker is not installed" or "permission denied" banner**: check that `docker ps` works in a normal terminal without `sudo`. If it does not, add your user to the `docker` group (`sudo usermod -aG docker $USER`), then log out and back in.
- **Run the sandboxed app from a terminal to see its messages**: `flatpak run es.agustin_garcia.DockStation`
- **Test Docker access from inside the sandbox**:

  ```sh
  flatpak run --command=flatpak-spawn es.agustin_garcia.DockStation --host docker compose version
  ```

## Translations

DockStation is available in English and Spanish (`po/es.po`). It follows the desktop language automatically. To try another language, run:

```sh
LANGUAGE=es ./build/src/dockstation
```

When run from the build folder, the app reads translations from the install location. So `meson install` it first, or use the Flatpak.

After changing text in the code, update the template and the translations:

```sh
meson compile -C build dockstation-pot        # regenerates po/dockstation.pot
meson compile -C build dockstation-update-po  # merges new strings into po/*.po
```

To add a language, create `po/<code>.po` from `po/dockstation.pot` (for example with `msginit -l fr -i po/dockstation.pot -o po/fr.po`), add the code to `po/LINGUAS`, and run `meson setup --reconfigure build`. Check a translation with `msgfmt --check --statistics po/<code>.po`.

## Custom services

The services offered by **Add Service** are folders. The built-in ones are in [`data/services`](data/services). To add your own, or to replace a built-in one, create a folder in:

- `~/.local/share/dockstation/services/`, or
- `~/.var/app/es.agustin_garcia.DockStation/data/dockstation/services/` for the Flatpak.

A folder with the same name as a built-in service replaces it. The dialog lists services that could not be loaded, and why. A service folder contains:

| File | Content |
| --- | --- |
| `service.ini` | Name, description, versions and options (below) |
| `compose.yaml` | The service's compose file |
| `env` | Optional: lines appended to the project's `.env` |
| `files/` | Optional: starter files copied into the project. Their paths may use placeholders, as in `files/{{FOLDER}}/index.html` |

```ini
[Service]
# Required: the version of this format.
Format=1
Name=Nginx
Description=Web server for the files in a folder
Description[es]=Servidor web para los archivos de una carpeta
# Lowercase letters, digits, "-" and "_".
DefaultName=nginx
# Optional: the port {{PORTS}} can publish, the suggested host port
# (default: ContainerPort), and whether to publish it by default.
ContainerPort=80
HostPort=8080
Publish=true

# One section per version, newest first; {{VERSION}} is the text after "Version ".
# Without versions, {{VERSION}} is "latest". UPPERCASE keys are placeholders
# for that version only.
[Version stable]
Description=Recommended for production
JDK=jdk21

# One section per setting the dialog asks for; its value fills {{FOLDER}}.
# Type is folder, service or text. Default may use {{SERVICE}}.
[Option FOLDER]
Type=folder
Title=Folder
Subtitle=The files to serve
Default={{SERVICE}}
```

Comments go on their own lines: `KeyFile` does not support comments after a value.

`Description`, `Title` and `Subtitle` can be translated with `Key[lang]` entries, as in desktop files. The option types are:

- `folder`: a folder inside the project. It is created if missing, so Docker does not create it owned by root.
- `service`: one of the project's services.
- `text`: free text, limited to letters, digits and `. _ / : @ -`, so it never needs quoting in YAML.

Placeholders in `{{UPPERCASE}}` work in every file. Besides the options and the version's own keys, these are always available:

| Placeholder | Value |
| --- | --- |
| `{{SERVICE}}` | The service name |
| `{{VERSION}}` | The chosen version |
| `{{VOLUME}}` | `<service>-data`, for the service's named volume. DockStation refuses to add the service if the project already has a volume with that name |
| `{{PASSWORD}}` | A generated password: put it in `env` |
| `{{PASSWORD_VAR}}`, `{{PASSWORD_REF}}` | `<SERVICE>_PASSWORD` and `${<SERVICE>_PASSWORD}` |
| `{{PREFIX}}` | The service name as a variable prefix: `my-db` gives `MY_DB` |
| `{{PORTS}}` | Only in `compose.yaml`, alone on its line: becomes the `ports:` entry (`127.0.0.1:${<SERVICE>_PORT}:<ContainerPort>`), or disappears when no port is published. The port goes to `.env` |

A placeholder without a value is an error, so a typo is reported instead of reaching the project. Starter files are skipped when the file exists, or when it would go into a `folder` option the user pointed at a folder that already has files.

The built-in services are compiled into the app: after adding a file to `data/services`, also list it in `data/dockstation.gresource.xml`.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Ctrl+N | New project |
| Ctrl+O | Add existing project |
| Ctrl+R / F5 | Refresh |
| Ctrl+S | Save the file being edited |
| Ctrl+Q | Quit |

## Where data is stored

- The project list: `~/.config/dockstation/projects.ini`, or `~/.var/app/es.agustin_garcia.DockStation/config/dockstation/projects.ini` for the Flatpak.
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
| `src/service-templates.vala` | Loads the services offered by Add Service |
| `src/add-service.vala` | Add Service dialog, and adding a service's files to a project |
| `src/new-project-dialog.vala` | New Project dialog |
| `src/resources.vala`, `src/resources-view.vala` | Docker Resources page: disk usage of containers, images and volumes by project |
| `src/service-row.vala`, `src/project-row.vala`, `src/log-view.vala` | Widgets |
| `src/utils.vala` | Helpers: port parsing, folder names, secrets |
| `data/` | Desktop entry, AppStream metadata, app icon and the built-in services (`data/services`) |
| `po/` | Translations (gettext) |

## License

GPL-3.0-or-later, as declared in `meson.build`. A `LICENSE` file has not been added yet.
