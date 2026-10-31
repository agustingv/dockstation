namespace DockStation {
    /* The Services tab: where the project is, its state, and a row for each service. */
    public class ServicesPage : Adw.Bin {
        public Project project { get; construct; }

        /* The services the configuration defines; see services_changed. */
        public string[] service_names { get; private set; default = {}; }

        /* `service_names` changed. */
        public signal void services_changed ();
        public signal void reload_requested ();
        public signal void service_action (ServiceRow row, string action);
        public signal void open_url (string url);

        private Cancellable cancellable = new Cancellable ();
        private ulong status_handler = 0;
        private Adw.ActionRow status_row;
        private Adw.PreferencesGroup services_group;
        private HashTable<string, ServiceRow> service_rows = new HashTable<string, ServiceRow> (str_hash, str_equal);
        // Services that can be removed; read from the files only when the configuration is reloaded.
        private string[] removable_services = {};
        private bool config_loaded = false;
        private bool refreshing_services = false;
        private bool actions_sensitive = true;
        // Databases that can be reset, keyed by container ID; inspected again when the IDs change.
        private HashTable<string, DatabaseInit> databases = new HashTable<string, DatabaseInit> (str_hash, str_equal);
        // Traefik addresses per container ID, read from the containers' labels.
        private HashTable<string, GenericArray<TraefikRoute>> traefik_routes =
            new HashTable<string, GenericArray<TraefikRoute>> (str_hash, str_equal);
        private string inspected_containers = "";
        private bool config_reload_pending = false;

        public ServicesPage (Project project) {
            Object (project: project);
        }

        construct {
            child = build_ui ();
            status_handler = project.status_changed.connect (update_status_row);
            update_status_row ();
        }

        /* Must be called before the page is discarded, to stop background work. */
        public void shutdown () {
            cancellable.cancel ();
            if (status_handler != 0) {
                project.disconnect (status_handler);
                status_handler = 0;
            }
        }

        public void set_actions_sensitive (bool sensitive) {
            actions_sensitive = sensitive;
            service_rows.foreach ((name, row) => row.set_actions_sensitive (sensitive));
        }

        private void forward_action (ServiceRow row, string action) {
            service_action (row, action);
        }

        private void forward_url (string url) {
            open_url (url);
        }

        private Gtk.Widget build_ui () {
            var folder_button = new Gtk.Button.from_icon_name ("folder-open-symbolic") {
                action_name = "project.open-folder",
                tooltip_text = _("Open Folder"),
                valign = Gtk.Align.CENTER,
            };
            folder_button.add_css_class ("flat");

            var location_row = new Adw.ActionRow () {
                title = _("Location"),
                subtitle = Utils.home_relative (project.path),
                subtitle_selectable = true,
            };
            location_row.add_css_class ("property");
            location_row.add_suffix (folder_button);

            status_row = new Adw.ActionRow () { title = _("Status") };
            status_row.add_css_class ("property");

            var info_group = new Adw.PreferencesGroup () { title = project.name };
            project.bind_property ("name", info_group, "title", BindingFlags.DEFAULT);
            info_group.add (location_row);
            info_group.add (status_row);

            var refresh_button = new Gtk.Button.from_icon_name ("view-refresh-symbolic") {
                tooltip_text = _("Refresh"),
                valign = Gtk.Align.CENTER,
            };
            refresh_button.add_css_class ("flat");
            refresh_button.clicked.connect (() => reload_requested ());

            var add_button = new Gtk.Button.from_icon_name ("list-add-symbolic") {
                action_name = "project.add-service",
                tooltip_text = _("Add Service…"),
                valign = Gtk.Align.CENTER,
            };
            add_button.add_css_class ("flat");

            var header_buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            header_buttons.append (add_button);
            header_buttons.append (refresh_button);

            services_group = new Adw.PreferencesGroup () {
                title = _("Services"),
                header_suffix = header_buttons,
            };

            var page = new Adw.PreferencesPage ();
            page.add (info_group);
            page.add (services_group);
            return page;
        }

        private void update_status_row () {
            status_row.subtitle = project.status_label;
        }

        /*
         * Updates the list. `containers` is the window's `docker ps` output for all
         * projects, which saves running it again; without it, this project's are queried.
         */
        public async void refresh (bool reload_config = false, GenericArray<ComposeContainer>? containers = null) {
            if (refreshing_services) {
                config_reload_pending = config_reload_pending || reload_config;
                return;
            }
            refreshing_services = true;

            try {
                if (!project.folder_exists) {
                    // No files to read: the services are just the containers that are left.
                    config_loaded = false;
                    service_names = {};
                    removable_services = {};
                    services_group.description = null;
                    services_changed ();
                } else if (reload_config || !config_loaded) {
                    var config = yield Docker.run (project.path, Docker.compose_args ({ "config", "--services" }), cancellable);
                    config_loaded = true;
                    removable_services = ServiceRemover.added_services (project);
                    if (config.success) {
                        service_names = Utils.split_lines (config.stdout_text);
                        services_group.description = null;
                    } else {
                        service_names = {};
                        services_group.description = config.stderr_text.strip ();
                    }
                    services_changed ();
                }

                var infos = new HashTable<string, ServiceInfo> (str_hash, str_equal);
                string[] order = {};
                foreach (unowned string name in service_names) {
                    infos[name] = new ServiceInfo ();
                    order += name;
                }

                if (containers == null) {
                    var ps = yield Docker.run (null, {
                        "ps", "--all",
                        "--filter", "label=com.docker.compose.project.working_dir=" + project.path,
                        "--format", Docker.COMPOSE_PS_FORMAT,
                    }, cancellable);
                    containers = ps.success ? ComposeContainer.parse (ps.stdout_text) : new GenericArray<ComposeContainer> ();
                }
                foreach (var container in containers) {
                    if (container.working_dir != project.path) {
                        continue;
                    }
                    var info = infos[container.service];
                    if (info == null) {
                        // Orphan container of a service no longer in the file.
                        info = new ServiceInfo ();
                        infos[container.service] = info;
                        order += container.service;
                    }
                    info.add_container (container.id, container.state, container.status, container.ports);
                }

                yield inspect_containers (infos, order);
                update_service_rows (infos, order);
            } catch (IOError.CANCELLED e) {
                return;
            } catch (Error e) {
                services_group.description = e.message;
            }

            refreshing_services = false;
            if (config_reload_pending) {
                config_reload_pending = false;
                yield refresh (true);
            }
        }

        /*
         * Reads what DockStation needs from the containers themselves: databases
         * with init scripts (see DatabaseInit) and Traefik routes (see Traefik).
         */
        private async void inspect_containers (HashTable<string, ServiceInfo> infos, string[] order) {
            string[] ids = {};
            foreach (unowned string name in order) {
                var info = infos[name];
                if (info.containers == 1 && info.container_id != "") {
                    ids += info.container_id;
                }
            }
            var key = string.joinv (",", ids);
            if (key == inspected_containers) {
                return;
            }
            try {
                databases = yield DatabaseInit.inspect (ids, cancellable);
                traefik_routes = yield Traefik.inspect (ids, cancellable);
                inspected_containers = key;
            } catch (Error e) {
                // Not critical: the reset and link buttons just stay hidden.
            }
        }

        private void update_service_rows (HashTable<string, ServiceInfo> infos, string[] order) {
            foreach (var name in service_rows.get_keys ()) {
                if (!infos.contains (name)) {
                    services_group.remove (service_rows[name]);
                    service_rows.remove (name);
                }
            }

            foreach (unowned string name in order) {
                var row = service_rows[name];
                if (row == null) {
                    row = new ServiceRow (name);
                    row.action_requested.connect (forward_action);
                    row.open_url.connect (forward_url);
                    row.set_actions_sensitive (actions_sensitive);
                    services_group.add (row);
                    service_rows[name] = row;
                }
                var info = infos[name];
                row.show_traefik_routes (info.container_id != "" ? traefik_routes[info.container_id] : null);
                row.update (info);
                row.show_database_reset (info.containers == 1 ? databases[info.container_id] : null);
                row.show_remove (name in removable_services);
            }

            if (order.length == 0 && services_group.description == null) {
                services_group.description = _("No services defined");
            }
        }
    }
}
