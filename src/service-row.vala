namespace DockStation {
    /* Aggregated state of one compose service (possibly several replicas). */
    public class ServiceInfo : Object {
        public string name;
        public int containers = 0;
        public int running = 0;
        public string state = "";
        public string status = "";
        public string ports = "";
        public string container_id = "";   // First container; replicas are not resettable one by one.

        public ServiceInfo (string name) {
            this.name = name;
        }

        public void add_container (string id, string state, string status, string ports) {
            containers++;
            if (containers == 1) {
                container_id = id;
            }
            if (state == "running") {
                running++;
            }
            if (containers == 1 || state == "running") {
                this.state = state;
                this.status = status;
            }
            if (ports != "") {
                this.ports = this.ports == "" ? ports : this.ports + ", " + ports;
            }
        }
    }

    public class ServiceRow : Adw.ActionRow {
        public string service { get; construct; }
        public int host_port { get; private set; default = 0; }

        public signal void action_requested (string action);
        public signal void open_url (string url);

        private Gtk.Image status_icon;
        private Gtk.Button open_button;
        private Gtk.Popover? links_popover = null;
        private Gtk.Box links_box;
        private ServiceInfo? info = null;
        private GenericArray<TraefikRoute> routes = new GenericArray<TraefikRoute> ();
        private Gtk.Button toggle_button;
        private Gtk.Button restart_button;
        private Gtk.Button reset_button;
        private Gtk.Button remove_button;
        private bool running = false;

        /* Set when the service is a database that can be reset from its init scripts. */
        public DatabaseInit? database { get; private set; default = null; }

        public ServiceRow (string service) {
            Object (service: service);
        }

        construct {
            title = service;
            use_markup = false;

            status_icon = new Gtk.Image.from_icon_name ("media-record-symbolic");
            add_prefix (status_icon);

            open_button = new Gtk.Button.from_icon_name ("web-browser-symbolic") {
                tooltip_text = _("Open in Browser"),
                valign = Gtk.Align.CENTER,
            };
            open_button.add_css_class ("flat");
            open_button.clicked.connect (on_open_clicked);
            add_suffix (open_button);

            links_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            links_popover = new Gtk.Popover () { child = links_box };
            links_popover.set_parent (open_button);
            toggle_button = add_button ("media-playback-start-symbolic", _("Start"), "toggle");
            restart_button = add_button ("system-reboot-symbolic", _("Restart"), "restart");
            reset_button = add_button ("document-revert-symbolic", _("Reset Database from Init Scripts"), "reset-database");
            reset_button.visible = false;
            add_button ("utilities-terminal-symbolic", _("Show Logs"), "logs");
            remove_button = add_button ("user-trash-symbolic", _("Remove Service…"), "remove-service");
            remove_button.visible = false;
        }

        public override void dispose () {
            if (links_popover != null) {
                links_popover.unparent ();
                links_popover = null;
            }
            base.dispose ();
        }

        /* Addresses Traefik routes to this service (see Traefik.routes_from_labels). */
        public void show_traefik_routes (GenericArray<TraefikRoute>? routes) {
            this.routes = routes ?? new GenericArray<TraefikRoute> ();
            refresh ();
        }

        /* A URL to open, with a short description of where it comes from. */
        private class Link {
            public string url;
            public string description;
        }

        private GenericArray<Link> links () {
            var result = new GenericArray<Link> ();
            for (uint i = 0; i < routes.length; i++) {
                var link = new Link ();
                link.url = routes[i].url;
                link.description = _("Traefik router “%s”").printf (routes[i].router);
                result.add (link);
            }
            if (host_port > 0) {
                var link = new Link ();
                link.url = "http://localhost:%d".printf (host_port);
                link.description = _("Port %d published on this computer").printf (host_port);
                result.add (link);
            }
            return result;
        }

        private void on_open_clicked () {
            var available = links ();
            if (available.length == 1) {
                open_url (available[0].url);
                return;
            }
            // Several addresses: let the user pick one.
            for (var child = links_box.get_first_child (); child != null; child = links_box.get_first_child ()) {
                links_box.remove (child);
            }
            for (uint i = 0; i < available.length; i++) {
                var url = available[i].url;
                var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
                content.append (new Gtk.Label (url) { xalign = 0 });
                var description = new Gtk.Label (available[i].description) { xalign = 0 };
                description.add_css_class ("caption");
                description.add_css_class ("dim-label");
                content.append (description);
                var button = new Gtk.Button () { child = content };
                button.add_css_class ("flat");
                button.clicked.connect (() => {
                    links_popover.popdown ();
                    open_url (url);
                });
                links_box.append (button);
            }
            links_popover.popup ();
        }

        public void show_database_reset (DatabaseInit? database) {
            this.database = database;
            reset_button.visible = database != null;
            if (database != null) {
                reset_button.tooltip_text = _("Reset the %s Database from Its Init Scripts").printf (database.engine);
            }
        }

        /* Only for services added with Add Service, which live in their own file. */
        public void show_remove (bool removable) {
            remove_button.visible = removable;
        }

        private Gtk.Button add_button (string icon, string tooltip, string action) {
            var button = new Gtk.Button.from_icon_name (icon) {
                tooltip_text = tooltip,
                valign = Gtk.Align.CENTER,
            };
            button.add_css_class ("flat");
            button.clicked.connect (() => {
                if (action == "toggle") {
                    action_requested (running ? "stop" : "start");
                } else {
                    action_requested (action);
                }
            });
            add_suffix (button);
            return button;
        }

        public void update (ServiceInfo info) {
            this.info = info;
            refresh ();
        }

        private void refresh () {
            if (info == null) {
                return;
            }
            running = info.running > 0;

            string text;
            if (info.containers == 0) {
                text = _("Not created");
            } else if (info.containers > 1) {
                text = _("%s (%d/%d running)").printf (info.status, info.running, info.containers);
            } else {
                text = info.status;
            }
            var ports = Utils.simplify_ports (info.ports);
            if (ports != "") {
                text += "  ·  " + ports;
            }
            string[] hosts = {};
            for (uint i = 0; i < routes.length; i++) {
                hosts += routes[i].display_host;
            }
            if (hosts.length > 0) {
                text += "  ·  " + string.joinv (", ", hosts);
            }
            subtitle = text;

            Utils.set_state_class (status_icon, info.containers == 0 ? "dim-label" : Utils.container_state_class (info.state));
            status_icon.tooltip_text = info.containers == 0 ? _("Not created") : info.state;

            host_port = Utils.first_host_port (info.ports);
            var available = links ();
            open_button.visible = running && available.length > 0;
            open_button.tooltip_text = available.length == 1
                ? _("Open %s").printf (available[0].url)
                : _("Open in Browser");

            toggle_button.icon_name = running ? "media-playback-stop-symbolic" : "media-playback-start-symbolic";
            toggle_button.tooltip_text = running ? _("Stop") : _("Start");
        }

        public void set_actions_sensitive (bool sensitive) {
            toggle_button.sensitive = sensitive;
            restart_button.sensitive = sensitive;
            reset_button.sensitive = sensitive;
            remove_button.sensitive = sensitive;
        }
    }
}
