## DockStation v0.1.9

### Internal
- The code that runs Docker commands is now a namespace instead of a class with only static methods, like the rest of the code of its kind. No changes in behavior.

## DockStation v0.1.8

### Internal
- The sidebar, the editor and the logs tab no longer use boolean flags to ignore their own changes: the signal handler is blocked during the change instead. No changes in behavior.

## DockStation v0.1.7

### Changes
- A container state DockStation does not recognize now reads "unknown" in its tooltip, instead of Docker's name for it.

### Internal
- Container states, service and tray actions, mount types and Docker usage types are now enums instead of strings, so the compiler catches typos and unhandled cases.

## DockStation v0.1.6

### Changes
- Removing a service now shows the full command in the Output tab, as resetting a database already did.
- Resetting a database checks that its data folder is safe to empty again right before running, not only before asking.

### Internal
- Resetting databases and removing services moved out of the project view, with unit tests for the order of their steps and for what happens when one fails.

## DockStation v0.1.5

### Changes
- A project's containers are inspected with one `docker inspect` instead of two.
- Project templates now fail with an error if a placeholder has no value, instead of writing it to the project's files. A project name containing a placeholder is no longer expanded.

### Internal
- The project view and the main window are split into smaller classes.
- Less duplicated code, and more unit tests.

## DockStation v0.1.4

### Fixes
- The message shown when Docker cannot be reached is readable again. It could show garbage, because it was read from memory that had already been freed.
- Logs no longer show stray terminal codes before each line.
- Quotes and other special characters display correctly in configuration and Docker errors.
- Generating a password now fails with an error instead of falling back to a weak random generator.

### Internal
- Unit tests, which also run when the packages are built.
- Less duplicated code, and removable services are no longer read from disk on every refresh.

## DockStation v0.1.3

### Fixes
- A project whose folder has already been deleted can now be deleted from DockStation.

## DockStation v0.1.2

### Packaging
- The `.rpm` recommends `libglvnd-gles`. Without it, DockStation aborts at startup, which could happen on Fedora desktops other than GNOME.

## DockStation v0.1.1

### Packaging
- `.deb` packages for Debian 13 and Ubuntu 25.10 or newer, and `.rpm` packages for Fedora 43 or newer and openSUSE Tumbleweed.
- A [download page](https://agustingv.github.io/dockstation/) on GitHub Pages.
- The packages add a signed repository, so DockStation updates through APT and DNF. On openSUSE, new versions have to be installed by hand.

## DockStation v0.1.0

First public release of DockStation, a GNOME app to manage your Docker Compose projects.

### Features
- **Project management**: keep all your Docker Compose projects in one place; start, stop and restart services and follow their logs.
- **Docker resource manager**: see containers, images, volumes and Docker's disk usage.
- **Configuration editor**: edit Compose files with syntax highlighting; the configuration is validated before it is saved.
- **Services in projects**: add ready-made services to a project from templates, including database services with init scripts.
- **Traefik integration**: links to the URLs that Traefik exposes for your services.
- **Background mode**: DockStation keeps running after you close the window, through the background portal.
- **Tray icon**: a status icon for quick access to the app.
- **Translations**: Spanish (es).

### Packaging
- Flatpak manifest built on the GNOME 51 runtime.
- The app ID is `io.github.agustingv.dockstation`.
