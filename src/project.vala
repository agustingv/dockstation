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
            foreach (unowned string name in service_files ()) {
                files += name;
            }
            files += ".env";
            return files;
        }

        /* Files of services added with "Add Service" (compose.<service>.yaml), sorted by name. */
        private string[] service_files () {
            var names = new GenericArray<string> ();
            try {
                var dir = Dir.open (path);
                string? name;
                while ((name = dir.read_name ()) != null) {
                    if (Regex.match_simple ("^compose\\..+\\.ya?ml$", name)
                        && !(name in OVERRIDE_FILE_NAMES)
                        && FileUtils.test (Path.build_filename (path, name), FileTest.IS_REGULAR)) {
                        names.add (name);
                    }
                }
            } catch (FileError e) {
                return {};
            }
            names.sort (strcmp);
            string[] sorted = {};
            foreach (unowned string name in names) {
                sorted += name;
            }
            return sorted;
        }

        /*
         * Absolute paths of the files `docker compose` loads when no -f option is given:
         * the ones in COMPOSE_FILE (from .env), or else the compose file and the first
         * override file found.
         */
        public string[] compose_files () {
            var listed = compose_files_from_env ();
            if (listed != null) {
                return listed;
            }
            string[] files = {};
            var compose = find_compose_file ();
            if (compose == null) {
                return files;
            }
            files += compose;
            foreach (unowned string name in OVERRIDE_FILE_NAMES) {
                var candidate = Path.build_filename (path, name);
                if (FileUtils.test (candidate, FileTest.IS_REGULAR)) {
                    files += candidate;
                    break;
                }
            }
            return files;
        }

        private string[]? compose_files_from_env () {
            string contents;
            try {
                FileUtils.get_contents (Path.build_filename (path, ".env"), out contents);
            } catch (Error e) {
                return null;
            }

            string? value = null;
            string separator = ":";
            foreach (unowned string raw in contents.split ("\n")) {
                var line = raw.strip ();
                if (line.has_prefix ("export ")) {
                    line = line.substring (7).strip ();
                }
                var equals = line.index_of ("=");
                if (line.has_prefix ("#") || equals <= 0) {
                    continue;
                }
                var key = line.substring (0, equals).strip ();
                var val = line.substring (equals + 1).strip ();
                if (val.length >= 2 && (val[0] == '"' || val[0] == '\'') && val[val.length - 1] == val[0]) {
                    val = val.substring (1, val.length - 2);
                }
                if (key == "COMPOSE_FILE") {
                    value = val;
                } else if (key == "COMPOSE_PATH_SEPARATOR" && val != "") {
                    separator = val;
                }
            }
            if (value == null || value == "") {
                return null;
            }

            string[] files = {};
            foreach (unowned string file in value.split (separator)) {
                if (file != "") {
                    files += Path.is_absolute (file) ? file : Path.build_filename (path, file);
                }
            }
            return files;
        }

        /* ------------------------------------------------------------ Dockerfiles */

        private const int DOCKERFILE_SEARCH_DEPTH = 4;
        private const int MAX_DOCKERFILES = 50;
        // Dependency, VCS and cache folders: large, and never hold the project's own Dockerfiles.
        private const string[] SKIPPED_DIRECTORIES = {
            ".git", ".hg", ".svn", ".cache", ".idea", ".vscode", ".flatpak", ".flatpak-builder",
            "node_modules", "vendor", ".venv", "venv", "__pycache__", "target"
        };

        public static bool is_dockerfile_name (string name) {
            var lower = name.down ();
            return lower == "dockerfile" || lower == "containerfile"
                || lower.has_prefix ("dockerfile.") || lower.has_suffix (".dockerfile");
        }

        /*
         * Searches the project folder for Dockerfiles, without following symlinks.
         * Returns paths relative to the project folder, shallowest first.
         */
        public async string[] find_dockerfiles (Cancellable? cancellable = null) {
            var root = File.new_for_path (path);
            var found = new GenericArray<string> ();
            yield search_dockerfiles (root, root, 0, found, cancellable);

            found.sort ((a, b) => {
                int depth = a.split ("/").length - b.split ("/").length;
                return depth != 0 ? depth : strcmp (a, b);
            });
            string[] result = {};
            for (uint i = 0; i < found.length; i++) {
                result += found[i];
            }
            return result;
        }

        private async void search_dockerfiles (File root, File dir, int depth, GenericArray<string> found,
                                               Cancellable? cancellable) {
            var subdirectories = new GenericArray<File> ();
            try {
                var enumerator = yield dir.enumerate_children_async (
                    FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.LOW, cancellable);
                while (true) {
                    var infos = yield enumerator.next_files_async (100, Priority.LOW, cancellable);
                    if (infos.length () == 0) {
                        break;
                    }
                    foreach (var info in infos) {
                        var name = info.get_name ();
                        var type = info.get_file_type ();
                        if (type == FileType.DIRECTORY) {
                            if (depth < DOCKERFILE_SEARCH_DEPTH && !(name in SKIPPED_DIRECTORIES)) {
                                subdirectories.add (dir.get_child (name));
                            }
                        } else if (type == FileType.REGULAR && is_dockerfile_name (name) && found.length < MAX_DOCKERFILES) {
                            found.add (root.get_relative_path (dir.get_child (name)));
                        }
                    }
                }
            } catch (Error e) {
                // Unreadable folder or cancelled search: keep what was found so far.
                return;
            }

            for (uint i = 0; i < subdirectories.length && found.length < MAX_DOCKERFILES; i++) {
                yield search_dockerfiles (root, subdirectories[i], depth + 1, found, cancellable);
            }
        }
    }
}
