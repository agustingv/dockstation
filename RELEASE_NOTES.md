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
