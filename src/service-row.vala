namespace DockStation {
    /* Aggregated state of one compose service (possibly several replicas). */
    public class ServiceInfo : Object {
        public string name;
        public int containers = 0;
        public int running = 0;
        public string state = "";
        public string status = "";
        public string ports = "";

        public ServiceInfo (string name) {
            this.name = name;
        }

        public void add_container (string state, string status, string ports) {
            containers++;
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

        private Gtk.Image status_icon;
        private Gtk.Button open_button;
        private Gtk.Button toggle_button;
        private Gtk.Button restart_button;
        private bool running = false;

        public ServiceRow (string service) {
            Object (service: service);
        }

        construct {
            title = service;
            use_markup = false;

            status_icon = new Gtk.Image.from_icon_name ("media-record-symbolic");
            add_prefix (status_icon);

            open_button = add_button ("web-browser-symbolic", _("Open in Browser"), "open");
            toggle_button = add_button ("media-playback-start-symbolic", _("Start"), "toggle");
            restart_button = add_button ("system-reboot-symbolic", _("Restart"), "restart");
            add_button ("utilities-terminal-symbolic", _("Show Logs"), "logs");
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
            subtitle = text;

            Utils.set_state_class (status_icon, info.containers == 0 ? "dim-label" : Utils.container_state_class (info.state));
            status_icon.tooltip_text = info.containers == 0 ? _("Not created") : info.state;

            host_port = Utils.first_host_port (info.ports);
            open_button.visible = running && host_port > 0;
            open_button.tooltip_text = _("Open http://localhost:%d").printf (host_port);

            toggle_button.icon_name = running ? "media-playback-stop-symbolic" : "media-playback-start-symbolic";
            toggle_button.tooltip_text = running ? _("Stop") : _("Start");
        }

        public void set_actions_sensitive (bool sensitive) {
            toggle_button.sensitive = sensitive;
            restart_button.sensitive = sensitive;
        }
    }
}
