namespace DockStation {
    public class Application : Adw.Application {
        public Application () {
            Object (application_id: Config.APP_ID, flags: ApplicationFlags.DEFAULT_FLAGS);
        }

        construct {
            ActionEntry[] entries = {
                { "about", on_about },
                { "quit", on_quit },
            };
            add_action_entries (entries, this);

            set_accels_for_action ("app.quit", { "<primary>q" });
            set_accels_for_action ("win.new-project", { "<primary>n" });
            set_accels_for_action ("win.add-project", { "<primary>o" });
            set_accels_for_action ("win.refresh", { "<primary>r", "F5" });
        }

        public override void startup () {
            base.startup ();
            GtkSource.init ();
        }

        public override void activate () {
            base.activate ();
            var win = active_window ?? new Window (this);
            win.present ();
        }

        /*
         * Closes the windows the normal way, so unsaved changes are still asked about,
         * then the app ends with the last window, also when it runs in the background.
         */
        private void on_quit () {
            var windows = get_windows ().copy ();
            if (windows.length () == 0) {
                quit ();
                return;
            }
            foreach (var window in windows) {
                if (window is Window) {
                    ((Window) window).quit_app ();
                } else {
                    window.close ();
                }
            }
        }

        private void on_about () {
            var about = new Adw.AboutDialog () {
                application_name = "DockStation",
                application_icon = Config.APP_ID,
                developer_name = "Agustin Garcia",
                version = Config.VERSION,
                comments = _("Manage and create Docker Compose projects"),
                license_type = Gtk.License.GPL_3_0,
                developers = { "Agustin Garcia <contacto@agustin-garcia.es>" },
                copyright = "© 2026 Agustin Garcia",
            };
            about.present (active_window);
        }
    }
}
