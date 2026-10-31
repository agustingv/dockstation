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

        private void add_init_mount (string type, string name, string source) {
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

        /* The container's database, or null if it is not one that can be reset. */
        public static DatabaseInit? from_container (ContainerDetails container) {
            var database = new DatabaseInit ();
            database.image_id = container.image_id;
            var pgdata = container.environment["PGDATA"];
            foreach (var mount in container.mounts) {
                unowned string destination = mount.destination;
                if (destination == INIT_DIR || destination.has_prefix (INIT_DIR + "/")) {
                    database.add_init_mount (mount.mount_type, mount.name, mount.source);
                    continue;
                }
                var detected = destination == pgdata ? "PostgreSQL" : engine_for_data_dir (destination);
                if (detected != null && (mount.mount_type == "volume" || mount.mount_type == "bind")) {
                    database.engine = detected;
                    database.data_type = mount.mount_type;
                    database.data_volume = mount.name;
                    database.data_source = mount.source;
                    database.data_destination = destination;
                }
            }
            return database.can_reset ? database : null;
        }
    }
}
