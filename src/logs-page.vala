namespace DockStation {
    /* The Logs tab: follows the logs of the project, or of one of its services. */
    public class LogsPage : Adw.Bin {
        public Project project { get; construct; }

        /* False until the tab is first needed, so no process runs for logs nobody looks at. */
        public bool started { get; private set; default = false; }

        private LogView logs_view;
        private Gtk.StringList logs_services_model;
        private Gtk.DropDown logs_service_dropdown;
        private Gtk.ToggleButton timestamps_toggle;
        private Cancellable? logs_cancellable = null;
        private ulong service_selected_handler;

        public LogsPage (Project project) {
            Object (project: project);
        }

        construct {
            child = build_ui ();
        }

        private Gtk.Widget build_ui () {
            logs_services_model = new Gtk.StringList ({ _("All Services") });
            logs_service_dropdown = new Gtk.DropDown (logs_services_model, null) { tooltip_text = _("Service") };
            service_selected_handler = logs_service_dropdown.notify["selected"].connect (() => restart ());

            timestamps_toggle = new Gtk.ToggleButton () {
                icon_name = "preferences-system-time-symbolic",
                tooltip_text = _("Show Timestamps"),
            };
            timestamps_toggle.toggled.connect (restart);

            var reload_button = new Gtk.Button.from_icon_name ("view-refresh-symbolic") { tooltip_text = _("Reload Logs") };
            reload_button.clicked.connect (restart);

            logs_view = new LogView ();

            var clear_button = new Gtk.Button.from_icon_name ("edit-clear-all-symbolic") { tooltip_text = _("Clear") };
            clear_button.clicked.connect (() => logs_view.clear ());

            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            bar.add_css_class ("toolbar");
            bar.append (logs_service_dropdown);
            bar.append (new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { hexpand = true });
            bar.append (timestamps_toggle);
            bar.append (reload_button);
            bar.append (clear_button);

            var toolbar = new Adw.ToolbarView () {
                content = logs_view,
                top_bar_style = Adw.ToolbarStyle.RAISED_BORDER,
            };
            toolbar.add_top_bar (bar);
            return toolbar;
        }

        /* The services the list offers, keeping the selected one if it still exists. */
        public void update_services (string[] service_names) {
            string? selected = null;
            if (logs_service_dropdown.selected > 0 && logs_service_dropdown.selected != Gtk.INVALID_LIST_POSITION) {
                selected = logs_services_model.get_string (logs_service_dropdown.selected);
            }

            uint position = 0;
            for (int i = 0; i < service_names.length; i++) {
                if (service_names[i] == selected) {
                    position = i + 1;
                }
            }
            Utils.without_handler (logs_service_dropdown, service_selected_handler, () => {
                logs_services_model.splice (1, logs_services_model.get_n_items () - 1, service_names);
                logs_service_dropdown.selected = position;
            });
        }

        /* Follows the logs of one service. */
        public void show_service (string service) {
            uint position = 0;
            for (uint i = 1; i < logs_services_model.get_n_items (); i++) {
                if (logs_services_model.get_string (i) == service) {
                    position = i;
                }
            }
            Utils.without_handler (logs_service_dropdown, service_selected_handler, () => {
                logs_service_dropdown.selected = position;
            });

            restart ();
        }

        public void stop () {
            if (logs_cancellable != null) {
                logs_cancellable.cancel ();
            }
        }

        /* Starts following the logs again from the last lines. */
        public void restart () {
            stop ();
            started = true;
            logs_view.clear ();

            var stream_cancellable = new Cancellable ();
            logs_cancellable = stream_cancellable;

            string[] args = { "logs", "--follow", "--no-color", "--tail", "500" };
            if (timestamps_toggle.active) {
                args += "--timestamps";
            }
            var selected = logs_service_dropdown.selected;
            if (selected > 0 && selected != Gtk.INVALID_LIST_POSITION) {
                args += logs_services_model.get_string (selected);
            }

            Docker.stream.begin (project.path, Docker.compose_args (args), (line) => {
                if (!stream_cancellable.is_cancelled ()) {
                    logs_view.append (line + "\n");
                }
            }, stream_cancellable, (obj, res) => {
                try {
                    Docker.stream.end (res);
                    if (!stream_cancellable.is_cancelled ()) {
                        logs_view.append ("— %s —\n".printf (_("Log stream ended")));
                    }
                } catch (IOError.CANCELLED e) {
                } catch (Error e) {
                    logs_view.append (e.message + "\n");
                }
            });
        }
    }
}
