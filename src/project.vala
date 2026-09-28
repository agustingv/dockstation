namespace DockStation {
    public enum ProjectState {
        UNKNOWN,
        NOT_CREATED,
        STOPPED,
        PARTIAL,
        RUNNING;

        public string to_label (int running, int total) {
            switch (this) {
                case NOT_CREATED:
                    return _("Not created");
                case STOPPED:
                    return _("Stopped");
                case PARTIAL:
                    return _("%d of %d running").printf (running, total);
                case RUNNING:
                    return ngettext ("%d container running", "%d containers running", running).printf (running);
                default:
                    return _("Unknown");
            }
        }

        public string to_css_class () {
            switch (this) {
                case RUNNING:
                    return "success";
                case PARTIAL:
                    return "warning";
                default:
                    return "dim-label";
            }
        }
    }

    public class Project : Object {
        public const string[] COMPOSE_FILE_NAMES = {
            "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"
        };
        public const string[] OVERRIDE_FILE_NAMES = {
            "compose.override.yaml", "compose.override.yml",
            "docker-compose.override.yaml", "docker-compose.override.yml"
        };

        public string name { get; set; }
        public string path { get; construct; }
        public int running { get; private set; default = 0; }
        public int total { get; private set; default = 0; }
        public bool known { get; private set; default = false; }

        public signal void status_changed ();

        public Project (string name, string path) {
            Object (name: name, path: path);
        }

        public ProjectState state {
            get {
                if (!known) {
                    return ProjectState.UNKNOWN;
                }
                if (total == 0) {
                    return ProjectState.NOT_CREATED;
                }
                if (running == 0) {
                    return ProjectState.STOPPED;
                }
                return running < total ? ProjectState.PARTIAL : ProjectState.RUNNING;
            }
        }

        public string status_label {
            owned get { return state.to_label (running, total); }
        }

        public void update_counts (int running, int total) {
            if (known && this.running == running && this.total == total) {
                return;
            }
            known = true;
            this.running = running;
            this.total = total;
            status_changed ();
        }

        public void mark_unknown () {
            if (known) {
                known = false;
                status_changed ();
            }
        }

        public static string? find_compose_file_in (string dir) {
            foreach (unowned string name in COMPOSE_FILE_NAMES) {
                var candidate = Path.build_filename (dir, name);
                if (FileUtils.test (candidate, FileTest.IS_REGULAR)) {
                    return candidate;
                }
            }
            return null;
        }

        public string? find_compose_file () {
            return find_compose_file_in (path);
        }

        /* Files worth showing in the editor, relative to the project folder. */
        public string[] editable_files () {
            string[] files = {};
            var compose = find_compose_file ();
            files += compose != null ? Path.get_basename (compose) : "compose.yaml";
            foreach (unowned string name in OVERRIDE_FILE_NAMES) {
                if (FileUtils.test (Path.build_filename (path, name), FileTest.IS_REGULAR)) {
                    files += name;
                }
            }
            files += ".env";
            if (FileUtils.test (Path.build_filename (path, "Dockerfile"), FileTest.IS_REGULAR)) {
                files += "Dockerfile";
            }
            return files;
        }
    }
}
