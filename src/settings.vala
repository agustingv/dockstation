namespace DockStation {
    /* User preferences, saved in ~/.config/dockstation/settings.ini */
    public class AppSettings : Object {
        private const string GROUP = "ui";

        public bool show_resources { get; set; default = true; }
        // Closing the window hides it; the app keeps running until Quit.
        public bool run_in_background { get; set; default = false; }

        private string settings_file;

        construct {
            settings_file = Path.build_filename (Environment.get_user_config_dir (), "dockstation", "settings.ini");
            load ();
            notify.connect (save);
        }

        private void load () {
            var keyfile = new KeyFile ();
            try {
                keyfile.load_from_file (settings_file, KeyFileFlags.NONE);
                if (keyfile.has_key (GROUP, "show-resources")) {
                    show_resources = keyfile.get_boolean (GROUP, "show-resources");
                }
                if (keyfile.has_key (GROUP, "run-in-background")) {
                    run_in_background = keyfile.get_boolean (GROUP, "run-in-background");
                }
            } catch (Error e) {
                // No settings saved yet: keep the defaults.
            }
        }

        private void save () {
            var keyfile = new KeyFile ();
            keyfile.set_boolean (GROUP, "show-resources", show_resources);
            keyfile.set_boolean (GROUP, "run-in-background", run_in_background);
            try {
                DirUtils.create_with_parents (Path.get_dirname (settings_file), 0755);
                keyfile.save_to_file (settings_file);
            } catch (Error e) {
                warning ("Could not save settings: %s", e.message);
            }
        }
    }
}
