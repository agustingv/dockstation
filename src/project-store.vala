namespace DockStation {
    /* Persists the list of known projects in ~/.config/dockstation/projects.ini */
    public class ProjectStore : Object {
        public GLib.ListStore projects { get; private set; }

        private string config_file;

        construct {
            projects = new GLib.ListStore (typeof (Project));
            config_file = Path.build_filename (Environment.get_user_config_dir (), "dockstation", "projects.ini");
        }

        private static int compare (Object a, Object b) {
            return ((Project) a).name.collate (((Project) b).name);
        }

        public void load () {
            var keyfile = new KeyFile ();
            try {
                keyfile.load_from_file (config_file, KeyFileFlags.NONE);
            } catch (Error e) {
                return;
            }
            foreach (unowned string group in keyfile.get_groups ()) {
                try {
                    var path = keyfile.get_string (group, "path");
                    var name = keyfile.has_key (group, "name") ? keyfile.get_string (group, "name") : Path.get_basename (path);
                    if (find_by_path (path) == null) {
                        projects.insert_sorted (new Project (name, path), compare);
                    }
                } catch (Error e) {
                    warning ("Ignoring invalid project entry %s: %s", group, e.message);
                }
            }
        }

        public void save () {
            var keyfile = new KeyFile ();
            for (uint i = 0; i < projects.get_n_items (); i++) {
                var project = (Project) projects.get_item (i);
                var group = "project-%u".printf (i);
                keyfile.set_string (group, "name", project.name);
                keyfile.set_string (group, "path", project.path);
            }
            try {
                DirUtils.create_with_parents (Path.get_dirname (config_file), 0755);
                keyfile.save_to_file (config_file);
            } catch (Error e) {
                warning ("Could not save projects: %s", e.message);
            }
        }

        public Project? find_by_path (string path) {
            for (uint i = 0; i < projects.get_n_items (); i++) {
                var project = (Project) projects.get_item (i);
                if (project.path == path) {
                    return project;
                }
            }
            return null;
        }

        public void add (Project project) {
            projects.insert_sorted (project, compare);
            save ();
        }

        public void remove (Project project) {
            uint position;
            if (projects.find (project, out position)) {
                projects.remove (position);
                save ();
            }
        }
    }
}
