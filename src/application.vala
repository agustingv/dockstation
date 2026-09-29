namespace DockStation {
    public class Application : Adw.Application {
        public Application () {
            Object (application_id: Config.APP_ID, flags: ApplicationFlags.DEFAULT_FLAGS);
        }

        construct {
            ActionEntry[] entries = {
                { "about", on_about },
                { "quit", quit },
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
