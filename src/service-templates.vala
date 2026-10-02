namespace DockStation {
    public errordomain ServiceTemplateError {
        INVALID,
    }

    public enum ServiceOptionType {
        TEXT,       // Free text
        FOLDER,     // A folder inside the project, created if missing
        SERVICE;    // One of the project's services

        public static ServiceOptionType? parse (string name) {
            switch (name) {
                case "text": return TEXT;
                case "folder": return FOLDER;
                case "service": return SERVICE;
                default: return null;
            }
        }
    }

    /* A setting the Add Service dialog asks for; its value fills the {{KEY}} placeholder. */
    public class ServiceOption : Object {
        public string key { get; construct; }
        public ServiceOptionType option_type { get; construct; }
        public string title { get; construct; }
        public string subtitle { get; construct; }
        // May contain {{SERVICE}}.
        public string default_value { get; construct; }

        public ServiceOption (string key, ServiceOptionType option_type, string title, string subtitle, string default_value) {
            Object (key: key, option_type: option_type, title: title, subtitle: subtitle, default_value: default_value);
        }
    }

    public class ServiceVersion : Object {
        public string name { get; construct; }
        public string description { get; construct; }
        // Placeholders with a value specific to this version.
        public HashTable<string, string> vars { get; default = new HashTable<string, string> (str_hash, str_equal); }

        public ServiceVersion (string name, string description) {
            Object (name: name, description: description);
        }
    }

    /*
     * A service that can be added to a project, read from a folder:
     *
     *   service.ini    metadata, versions and options (see README.md, "Custom services")
     *   compose.yaml   the service's compose file
     *   env            lines appended to .env (optional)
     *   files/         starter files copied into the project (optional)
     *
     * Every file, and the paths under files/, may use {{PLACEHOLDERS}}.
     */
    public class ServiceTemplate : Object {
        public const int FORMAT = 1;

        public string id { get; construct; }
        public string name { get; private set; }
        public string description { get; private set; default = ""; }
        public string default_service { get; private set; }
        public int container_port { get; private set; default = 0; }
        public int default_host_port { get; private set; default = 0; }
        public bool publish_by_default { get; private set; default = false; }
        public ServiceVersion[] versions = {};
        public ServiceOption[] options = {};

        public string compose_template { get; private set; }
        public string env_template { get; private set; default = ""; }
        // Starter files: paths relative to files/, and their contents.
        public string[] file_paths { get; private set; default = {}; }
        public string[] file_contents { get; private set; default = {}; }

        private ServiceTemplate (string id) {
            Object (id: id);
        }

        public bool can_publish {
            get { return container_port > 0; }
        }

        public bool uses_volume {
            get { return compose_template.contains ("{{VOLUME}}"); }
        }

        /* The .env variable prefix for a service: "my-db" → "MY_DB". */
        public static string env_prefix (string service) {
            return service.up ().replace ("-", "_");
        }

        public static string port_var (string service) {
            return env_prefix (service) + "_PORT";
        }

        public static string volume_name (string service) {
            return service + "-data";
        }

        public static bool is_valid_service_name (string name) {
            return Regex.match_simple ("^[a-z][a-z0-9_-]*$", name);
        }

        private static bool is_placeholder_name (string name) {
            return Regex.match_simple ("^[A-Z][A-Z0-9_]*$", name);
        }

        /* ------------------------------------------------------------------- loading */

        public static ServiceTemplate load (File dir) throws Error {
            var template = new ServiceTemplate (dir.get_basename ());
            var ini = new KeyFile ();
            ini.load_from_data (read_file (dir.get_child ("service.ini")), -1, KeyFileFlags.NONE);

            const string MAIN = "Service";
            var format = ini.get_integer (MAIN, "Format");
            if (format != FORMAT) {
                throw new ServiceTemplateError.INVALID (_("Unsupported format %d").printf (format));
            }
            template.name = ini.get_string (MAIN, "Name");
            template.description = optional_locale_string (ini, MAIN, "Description");
            template.default_service = ini.get_string (MAIN, "DefaultName");
            if (!is_valid_service_name (template.default_service)) {
                throw new ServiceTemplateError.INVALID (_("Invalid DefaultName “%s”").printf (template.default_service));
            }
            if (ini.has_key (MAIN, "ContainerPort")) {
                template.container_port = ini.get_integer (MAIN, "ContainerPort");
                template.default_host_port = ini.has_key (MAIN, "HostPort")
                    ? ini.get_integer (MAIN, "HostPort") : template.container_port;
                template.publish_by_default = ini.has_key (MAIN, "Publish") && ini.get_boolean (MAIN, "Publish");
            }

            ServiceVersion[] versions = {};
            ServiceOption[] options = {};
            foreach (unowned string group in ini.get_groups ()) {
                if (group.has_prefix ("Version ")) {
                    var version = new ServiceVersion (group.substring ("Version ".length).strip (),
                                                      optional_locale_string (ini, group, "Description"));
                    foreach (unowned string key in ini.get_keys (group)) {
                        if (is_placeholder_name (key)) {
                            version.vars[key] = ini.get_string (group, key);
                        }
                    }
                    versions += version;
                } else if (group.has_prefix ("Option ")) {
                    var key = group.substring ("Option ".length).strip ();
                    if (!is_placeholder_name (key)) {
                        throw new ServiceTemplateError.INVALID (_("Invalid option name “%s”").printf (key));
                    }
                    var type_name = ini.get_string (group, "Type");
                    var type = ServiceOptionType.parse (type_name);
                    if (type == null) {
                        throw new ServiceTemplateError.INVALID (_("Unknown option type “%s”").printf (type_name));
                    }
                    options += new ServiceOption (key, type,
                                                  ini.get_locale_string (group, "Title"),
                                                  optional_locale_string (ini, group, "Subtitle"),
                                                  ini.has_key (group, "Default") ? ini.get_string (group, "Default") : "");
                } else if (group != MAIN) {
                    throw new ServiceTemplateError.INVALID (_("Unknown section [%s]").printf (group));
                }
            }
            if (versions.length == 0) {
                versions += new ServiceVersion ("latest", "");
            }
            template.versions = versions;
            template.options = options;

            template.compose_template = read_file (dir.get_child ("compose.yaml"));
            var env = dir.get_child ("env");
            if (env.query_exists ()) {
                template.env_template = read_file (env);
            }
            // query_exists () is false for folders in resources, so look inside directly.
            var files = dir.get_child ("files");
            var paths = new GenericArray<string> ();
            var contents = new GenericArray<string> ();
            try {
                collect_files (files, files, paths, contents);
            } catch (IOError.NOT_FOUND e) {
            }
            if (paths.length > 0) {
                string[] path_array = {};
                string[] content_array = {};
                for (uint i = 0; i < paths.length; i++) {
                    path_array += paths[i];
                    content_array += contents[i];
                }
                template.file_paths = path_array;
                template.file_contents = content_array;
            }
            return template;
        }

        private static string optional_locale_string (KeyFile ini, string group, string key) throws Error {
            return ini.has_key (group, key) ? ini.get_locale_string (group, key) : "";
        }

        private static string read_file (File file) throws Error {
            uint8[] contents;
            file.load_contents (null, out contents, null);
            var text = (string) contents;
            if (!text.validate ()) {
                throw new ServiceTemplateError.INVALID (_("%s is not UTF-8 text").printf (file.get_basename ()));
            }
            return text;
        }

        private static void collect_files (File root, File dir, GenericArray<string> paths,
                                           GenericArray<string> contents) throws Error {
            var children = dir.enumerate_children ("standard::name,standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = children.next_file ()) != null) {
                var child = dir.get_child (info.get_name ());
                if (info.get_file_type () == FileType.DIRECTORY) {
                    collect_files (root, child, paths, contents);
                } else if (info.get_file_type () == FileType.REGULAR) {
                    paths.add (root.get_relative_path (child));
                    contents.add (read_file (child));
                }
            }
        }

        /* ----------------------------------------------------------------- rendering */

        /*
         * Replaces {{NAME}} placeholders with their values. A placeholder without a value
         * is an error, so mistakes in a template show up instead of reaching the project.
         */
        public static string substitute (string text, HashTable<string, string> vars) throws Error {
            string? unknown = null;
            var result = /\{\{([A-Z][A-Z0-9_]*)\}\}/.replace_eval (text, -1, 0, 0, (info, builder) => {
                var key = info.fetch (1);
                var value = vars[key];
                if (value == null) {
                    unknown = unknown ?? key;
                    builder.append (info.fetch (0));
                } else {
                    builder.append (value);
                }
                return false;
            });
            if (unknown != null) {
                throw new ServiceTemplateError.INVALID (_("Unknown placeholder {{%s}}").printf (unknown));
            }
            return result;
        }

        /*
         * The service's compose file. A line holding only {{PORTS}} becomes the published
         * port (reachable at localhost only) or disappears when `host_port` is 0.
         */
        public string render_compose (HashTable<string, string> vars, string service, int host_port) throws Error {
            var text = /^([ \t]*)\{\{PORTS\}\}[ \t]*\n/m.replace_eval (compose_template, -1, 0, 0, (info, builder) => {
                if (host_port > 0 && can_publish) {
                    var indent = info.fetch (1);
                    builder.append ("%sports:\n%s  - \"127.0.0.1:${%s}:%d\"\n".printf (
                        indent, indent, port_var (service), container_port));
                }
                return false;
            });
            return substitute (text, vars);
        }

        /* Lines to append to .env, or "" if the service needs none. */
        public string render_env (HashTable<string, string> vars, string service, int host_port) throws Error {
            var text = substitute (env_template, vars);
            if (host_port > 0 && can_publish) {
                if (text != "" && !text.has_suffix ("\n")) {
                    text += "\n";
                }
                text += "%s=%d\n".printf (port_var (service), host_port);
            }
            return text;
        }
    }

    namespace ServiceTemplates {
        private const string RESOURCE_DIR = "resource:///io/github/agustingv/dockstation/services";

        /* Folder for services written by the user; they replace built-in ones with the same folder name. */
        public string user_dir () {
            return Path.build_filename (Environment.get_user_data_dir (), "dockstation", "services");
        }

        /*
         * The built-in services and the user's, sorted by name. Services that cannot be
         * loaded are skipped and described in `problems`.
         */
        public ServiceTemplate[] load_all (out string[] problems) {
            var by_id = new HashTable<string, ServiceTemplate> (str_hash, str_equal);
            var found_problems = new GenericArray<string> ();
            load_dir (File.new_for_uri (RESOURCE_DIR), by_id, found_problems);
            load_dir (File.new_for_path (user_dir ()), by_id, found_problems);
            string[] problem_array = {};
            foreach (unowned string problem in found_problems) {
                problem_array += problem;
            }
            problems = problem_array;

            var sorted = new GenericArray<ServiceTemplate> ();
            by_id.foreach ((id, template) => sorted.add (template));
            sorted.sort ((a, b) => a.name.collate (b.name));
            ServiceTemplate[] result = {};
            foreach (var template in sorted) {
                result += template;
            }
            return result;
        }

        private void load_dir (File dir, HashTable<string, ServiceTemplate> by_id, GenericArray<string> problems) {
            FileEnumerator children;
            try {
                children = dir.enumerate_children ("standard::name,standard::type", FileQueryInfoFlags.NONE);
            } catch (IOError.NOT_FOUND e) {
                return;
            } catch (Error e) {
                problems.add ("%s: %s".printf (dir.get_parse_name (), e.message));
                return;
            }
            try {
                FileInfo? info;
                while ((info = children.next_file ()) != null) {
                    if (info.get_file_type () != FileType.DIRECTORY) {
                        continue;
                    }
                    var child = dir.get_child (info.get_name ());
                    try {
                        var template = ServiceTemplate.load (child);
                        by_id[template.id] = template;
                    } catch (Error e) {
                        warning ("Could not load the service in %s: %s", child.get_parse_name (), e.message);
                        problems.add ("%s: %s".printf (info.get_name (), e.message));
                    }
                }
            } catch (Error e) {
                problems.add ("%s: %s".printf (dir.get_parse_name (), e.message));
            }
        }
    }
}
