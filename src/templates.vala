namespace DockStation {
    public enum ComposerSupport {
        NONE,       // Not a PHP template
        OPTIONAL,   // The user chooses whether the image gets Composer
        INCLUDED,   // The base image already ships Composer
        REQUIRED;   // The template cannot work without Composer

        public static ComposerSupport? parse (string name) {
            switch (name) {
                case "optional": return OPTIONAL;
                case "included": return INCLUDED;
                case "required": return REQUIRED;
                default: return null;
            }
        }
    }

    /*
     * A project skeleton, read from a folder:
     *
     *   template.ini   name, description, default port and PHP support
     *   files/         the project's files
     *
     * File contents may contain {{NAME}}, {{NAME_HTML}}, {{SLUG}}, {{PORT}}, {{PASSWORD}},
     * {{UID}}, {{GID}}, {{PHP_VERSION}} and {{COMPOSER_INSTALL}} placeholders.
     */
    public class Template : Object {
        public const int FORMAT = 1;

        public string name { get; private set; }
        public string description { get; private set; default = ""; }
        public int default_port { get; private set; default = 0; }

        /* PHP versions the template supports, oldest first. Empty if it does not use PHP. */
        public string[] php_versions { get; private set; default = {}; }
        public string default_php_version { get; private set; default = ""; }
        public string php_note { get; private set; default = ""; }
        public ComposerSupport composer { get; private set; default = ComposerSupport.NONE; }
        public bool composer_default { get; private set; default = false; }

        private string[] paths = {};
        private string[] contents = {};

        public bool uses_port {
            get { return default_port > 0; }
        }

        public bool uses_php {
            get { return php_versions.length > 0; }
        }

        public static Template load (File dir) throws Error {
            var template = new Template ();
            var ini = new KeyFile ();
            ini.load_from_data (ServiceTemplate.read_file (dir.get_child ("template.ini")), -1, KeyFileFlags.NONE);

            const string MAIN = "Template";
            var format = ini.get_integer (MAIN, "Format");
            if (format != FORMAT) {
                throw new ServiceTemplateError.INVALID (_("Unsupported format %d").printf (format));
            }
            template.name = ini.get_locale_string (MAIN, "Name");
            template.description = ini.get_locale_string (MAIN, "Description");
            if (ini.has_key (MAIN, "Port")) {
                template.default_port = ini.get_integer (MAIN, "Port");
            }

            const string PHP = "PHP";
            if (ini.has_group (PHP)) {
                template.php_versions = ini.get_string_list (PHP, "Versions");
                template.default_php_version = ini.get_string (PHP, "Default");
                template.php_note = ini.get_locale_string (PHP, "Note");
                var composer_name = ini.get_string (PHP, "Composer");
                var composer = ComposerSupport.parse (composer_name);
                if (composer == null) {
                    throw new ServiceTemplateError.INVALID (_("Unknown Composer support “%s”").printf (composer_name));
                }
                template.composer = composer;
                template.composer_default = composer != ComposerSupport.OPTIONAL || ini.get_boolean (PHP, "ComposerEnabled");
            }

            var files = dir.get_child ("files");
            var paths = new GenericArray<string> ();
            var contents = new GenericArray<string> ();
            ServiceTemplate.collect_files (files, files, paths, contents);
            template.paths = Utils.to_array (paths);
            template.contents = Utils.to_array (contents);
            return template;
        }

        public void write_to (File dir, HashTable<string, string> vars) throws Error {
            ensure_directory (dir);
            for (int i = 0; i < paths.length; i++) {
                var file = dir.resolve_relative_path (paths[i]);
                ensure_directory (file.get_parent ());
                var text = ServiceTemplate.substitute (contents[i], vars);
                file.replace_contents (text.data, null, false, FileCreateFlags.NONE, null);
            }
        }

        private static void ensure_directory (File dir) throws Error {
            try {
                dir.make_directory_with_parents ();
            } catch (IOError.EXISTS e) {
            }
        }
    }

    namespace Templates {
        private const string RESOURCE_DIR = "resource:///io/github/agustingv/dockstation/templates";

        /* The folders in data/templates, in the order the New Project dialog lists them. */
        public const string[] BUILT_IN = {
            "blank",
            "static-website",
            "postgres-adminer",
            "php",
            "wordpress",
            "drupal",
            "nodejs",
            "python",
            "symfony",
        };

        /* Replaces {{COMPOSER_INSTALL}} in PHP Dockerfiles when Composer is enabled. */
        public const string COMPOSER_DOCKERFILE = """
# Composer, to manage PHP dependencies
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
ENV COMPOSER_HOME=/tmp/composer COMPOSER_ALLOW_SUPERUSER=1
""";

        private Template load_built_in (string id) throws Error {
            return Template.load (File.new_for_uri (RESOURCE_DIR + "/" + id));
        }

        public Template blank () throws Error {
            return load_built_in ("blank");
        }

        public Template[] all () {
            Template[] result = {};
            foreach (unowned string id in BUILT_IN) {
                try {
                    result += load_built_in (id);
                } catch (Error e) {
                    warning ("Could not load the template %s: %s", id, e.message);
                }
            }
            return result;
        }
    }
}
