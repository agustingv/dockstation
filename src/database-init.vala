namespace DockStation {
    /*
     * A database container whose official image runs the scripts in
     * /docker-entrypoint-initdb.d when its data folder is empty. Resetting it
     * means emptying the data and starting it again, so the image's own
     * entrypoint re-runs every script (.sql, .sql.gz, .sh, …) with the same
     * environment variables as the first time.
     */
    public class DatabaseInit : Object {
        public const string INIT_DIR = "/docker-entrypoint-initdb.d";

        public string container_id;
        public string image_id;
        public string engine;

        /* Where the data lives: a volume ("volume") or a host folder ("bind"). */
        public string data_type;
        public string data_volume;        // Volume name, for "volume"
        public string data_source;        // Host folder, for "bind"
        public string data_destination;

        private string[] script_files = {};
        private string[] script_volumes = {};

        /* Host paths of the init scripts, when they are bind-mounted, in the order they run. */
        public string[] init_files {
            get { return script_files; }
        }

        /* Volumes mounted on the init folder, whose files cannot be listed from here. */
        public string[] init_volumes {
            get { return script_volumes; }
        }

        public bool data_is_anonymous_volume {
            get { return data_type == "volume" && is_anonymous_volume_name (data_volume); }
        }

        private static bool is_anonymous_volume_name (string name) {
            if (name.length != 64) {
                return false;
            }
            for (int i = 0; i < name.length; i++) {
                if (!name[i].isxdigit ()) {
                    return false;
                }
            }
            return true;
        }

        /* Data folders of the official images that support docker-entrypoint-initdb.d. */
        private static string? engine_for_data_dir (string destination) {
            switch (destination) {
                case "/var/lib/postgresql/data":
                case "/var/lib/postgresql":      // PostgreSQL 18 and later
                    return "PostgreSQL";
                case "/var/lib/mysql":
                    return "MySQL / MariaDB";
                case "/data/db":
                    return "MongoDB";
                default:
                    return null;
            }
        }

        private static bool is_init_script (string name) {
            foreach (unowned string suffix in new string[] {
                    ".sql", ".sql.gz", ".sql.xz", ".sql.zst", ".sql.bz2", ".sh", ".js" }) {
                if (name.has_suffix (suffix)) {
                    return true;
                }
            }
            return false;
        }

        private void add_init_mount (string type, string name, string source, string destination) {
            if (type == "bind") {
                if (FileUtils.test (source, FileTest.IS_DIR)) {
                    try {
                        var dir = Dir.open (source);
                        string? entry;
                        string[] names = {};
                        while ((entry = dir.read_name ()) != null) {
                            if (is_init_script (entry)) {
                                names += entry;
                            }
                        }
                        // The entrypoint runs the scripts in alphabetical order.
                        qsort_with_data<string> (names, sizeof (string), (a, b) => strcmp (a, b));
                        foreach (unowned string file in names) {
                            script_files += Path.build_filename (source, file);
                        }
                    } catch (FileError e) {
                        // Unreadable folder: treat it as having no listable scripts.
                    }
                } else if (is_init_script (source)) {
                    script_files += source;
                }
            } else if (type == "volume" && name != "") {
                script_volumes += name;
            }
        }

        /* True when there is something to re-run and a data folder to empty. */
        public bool can_reset {
            get { return data_destination != null && (init_files.length > 0 || init_volumes.length > 0); }
        }

        /*
         * Inspects containers (by full or short ID) and returns the resettable
         * databases among them, keyed by the IDs as given.
         */
        public static async HashTable<string, DatabaseInit> inspect (string[] container_ids, Cancellable? cancellable)
                throws Error {
            var result = new HashTable<string, DatabaseInit> (str_hash, str_equal);
            if (container_ids.length == 0) {
                return result;
            }

            // Mounts come back as maps: bind mounts have no "Name" key, hence `index`.
            string[] args = {
                "inspect", "--type", "container", "--format",
                "C\t{{.Id}}\t{{.Image}}\n"
                + "{{range .Mounts}}M\t{{.Type}}\t{{index . \"Name\"}}\t{{.Source}}\t{{.Destination}}\n{{end}}"
                + "{{range .Config.Env}}E\t{{.}}\n{{end}}"
            };
            foreach (unowned string id in container_ids) {
                args += id;
            }
            var output = yield Docker.run (null, args, cancellable);

            DatabaseInit? current = null;
            string? pgdata = null;
            string[] mounts = {};
            foreach (unowned string line in (output.stdout_text + "C\n").split ("\n")) {
                var f = line.split ("\t");
                if (f[0] == "C") {
                    if (current != null) {
                        current.finish (mounts, pgdata);
                        // Key by the ID the caller passed, which may be the short form.
                        foreach (unowned string id in container_ids) {
                            if (current.can_reset && current.container_id.has_prefix (id)) {
                                result[id] = current;
                            }
                        }
                    }
                    if (f.length < 3) {
                        current = null;
                        continue;
                    }
                    current = new DatabaseInit ();
                    current.container_id = f[1];
                    current.image_id = f[2];
                    pgdata = null;
                    mounts = {};
                } else if (current != null && f[0] == "M" && f.length >= 5) {
                    mounts += line;
                } else if (current != null && f[0] == "E" && line.has_prefix ("E\tPGDATA=")) {
                    pgdata = line.substring ("E\tPGDATA=".length);
                }
            }
            return result;
        }

        private void finish (string[] mounts, string? pgdata) {
            foreach (unowned string line in mounts) {
                var f = line.split ("\t");
                var type = f[1];
                var name = f[2] == "<no value>" ? "" : f[2];
                var source = f[3];
                var destination = f[4];

                if (destination == INIT_DIR || destination.has_prefix (INIT_DIR + "/")) {
                    add_init_mount (type, name, source, destination);
                    continue;
                }
                var detected = destination == pgdata ? "PostgreSQL" : engine_for_data_dir (destination);
                if (detected != null && (type == "volume" || type == "bind")) {
                    engine = detected;
                    data_type = type;
                    data_volume = name;
                    data_source = source;
                    data_destination = destination;
                }
            }
        }
    }
}
