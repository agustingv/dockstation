namespace DockStation {
    /* What removing a service changes; see ServiceRemover.prepare (). */
    public class ServiceRemoval : Object {
        public string service;
        public string main_path;
        public string new_main;
        public File service_file;
        public File env_file;
        // Null when .env stays as it is.
        public string? new_env = null;
        // Docker volumes that only this service uses.
        public string[] volumes = {};
    }

    /* Removes services added with Add Service (see ServiceAdder). */
    namespace ServiceRemover {
        private const string FILE_PATTERN = "^(\\./)?compose\\.(" + ServiceTemplate.NAME_PATTERN + ")\\.yaml$";

        /* The project's services that have their own included compose.<service>.yaml. */
        public string[] added_services (Project project) {
            var files = project.compose_files ();
            string text;
            try {
                if (files.length == 0) {
                    return {};
                }
                FileUtils.get_contents (files[0], out text);
            } catch (Error e) {
                return {};
            }
            var include = new ComposeInclude (text.split ("\n"));
            string[] services = {};
            var dir = Path.get_dirname (files[0]);
            try {
                var pattern = new Regex (FILE_PATTERN);
                foreach (unowned string path in include.paths) {
                    MatchInfo match;
                    if (pattern.match (path, 0, out match)
                        && FileUtils.test (Path.build_filename (dir, path), FileTest.IS_REGULAR)) {
                        services += match.fetch (2);
                    }
                }
            } catch (RegexError e) {
                critical ("Invalid service file pattern: %s", e.message);
            }
            return services;
        }

        /*
         * Removes `path` from the `include:` list, and the list itself when it becomes
         * empty. Returns null if the list does not have that item.
         */
        public string? remove_include (string text, string path) {
            string[] lines = text.split ("\n");
            var include = new ComposeInclude (lines);

            int remove_line = -1;
            for (int i = 0; i < include.paths.length; i++) {
                if (include.paths[i] == path || include.paths[i] == "./" + path) {
                    remove_line = include.item_lines[i];
                }
            }
            if (remove_line < 0) {
                return null;
            }

            bool list_empty = include.item_lines.length == 1;
            string[] result = {};
            for (int i = 0; i < lines.length; i++) {
                if (i == remove_line || (list_empty && i == include.key_line)) {
                    continue;
                }
                // Do not leave two blank lines where the list was.
                if (list_empty && i == remove_line + 1 && lines[i].strip () == ""
                    && (result.length == 0 || result[result.length - 1].strip () == "")) {
                    continue;
                }
                result += lines[i];
            }
            return string.joinv ("\n", result);
        }

        /*
         * Removes the block Add Service appended to .env: the "# <service>" line and the
         * <PREFIX>_ variables after it. Returns the text unchanged if there is no such block.
         */
        public string remove_env_block (string text, string service) {
            string[] lines = text.split ("\n");
            var prefix = ServiceTemplate.env_prefix (service) + "_";
            string[] result = {};
            for (int i = 0; i < lines.length; i++) {
                if (lines[i].strip () != "# " + service) {
                    result += lines[i];
                    continue;
                }
                // Also drop the blank line written before the block.
                if (result.length > 0 && result[result.length - 1].strip () == "") {
                    result.resize (result.length - 1);
                }
                while (i + 1 < lines.length && lines[i + 1].has_prefix (prefix)) {
                    i++;
                }
            }
            return string.joinv ("\n", result);
        }

        /* The project's name in the output of `docker compose config`. */
        private string? project_name_in_config (string config) {
            foreach (unowned string line in config.split ("\n")) {
                if (line.has_prefix ("name:")) {
                    return line.substring ("name:".length).strip ();
                }
            }
            return null;
        }

        /*
         * Checks that the project stays valid without the service and finds its data volumes.
         * Nothing is changed yet: the caller removes the container, then calls apply ().
         */
        public async ServiceRemoval prepare (Project project, string service) throws Error {
            var files = project.compose_files ();
            if (files.length == 0) {
                throw new IOError.NOT_FOUND (_("The project has no compose file"));
            }
            var removal = new ServiceRemoval ();
            removal.service = service;
            removal.main_path = files[0];
            var file_name = ServiceTemplate.compose_file_name (service);
            removal.service_file = File.new_for_path (Path.build_filename (Path.get_dirname (removal.main_path), file_name));

            string main_text;
            FileUtils.get_contents (removal.main_path, out main_text);
            removal.new_main = remove_include (main_text, file_name);
            if (removal.new_main == null) {
                throw new IOError.NOT_FOUND (_("%s does not include %s").printf (Path.get_basename (removal.main_path), file_name));
            }

            removal.env_file = File.new_for_path (Path.build_filename (project.path, ".env"));
            string env_text = "";
            if (removal.env_file.query_exists ()) {
                FileUtils.get_contents (removal.env_file.get_path (), out env_text);
            }
            var new_env = remove_env_block (env_text, service);
            string[] removed_keys = {};
            var kept_keys = Utils.env_keys (new_env);
            foreach (unowned string key in Utils.env_keys (env_text)) {
                if (!(key in kept_keys)) {
                    removed_keys += key;
                }
            }

            // The service's volumes, and the project's name, which prefixes the volumes in Docker.
            var own = yield Docker.run (project.path, Docker.compose_args ({ "-f", removal.service_file.get_path (), "config", "--volumes" }));
            var own_volumes = own.success ? Utils.split_lines (own.stdout_text) : new string[0];
            var full = yield Docker.run (project.path, Docker.compose_args ({ "config" }));
            var project_name = full.success ? project_name_in_config (full.stdout_text) : null;

            // The project without the service: it must stay valid.
            var overlay = new ComposeOverlay (files);
            try {
                overlay.replace_file (removal.main_path, removal.new_main);
                if (new_env != env_text) {
                    overlay.replace_env (removal.env_file.get_path (), new_env);
                }
                var result = yield Docker.run (project.path, overlay.compose_args ({ "config", "--volumes" }));
                if (!result.success) {
                    throw new IOError.FAILED (overlay.restore_paths (result.stderr_text.strip ()));
                }

                // Variables still used elsewhere, such as a password another service reads, stay in .env.
                // Compose warns `The "KEY" variable is not set`, with escaped quotes in its log format.
                bool still_used = false;
                foreach (unowned string key in removed_keys) {
                    still_used |= result.stderr_text.contains ("\"%s\" variable is not set".printf (key))
                        || result.stderr_text.contains ("\\\"%s\\\" variable is not set".printf (key));
                }
                if (new_env != env_text && !still_used) {
                    removal.new_env = new_env;
                }

                // Volumes that other services still use are kept.
                var remaining = Utils.split_lines (result.stdout_text);
                string[] volumes = {};
                foreach (unowned string volume in own_volumes) {
                    if (volume in remaining || project_name == null) {
                        continue;
                    }
                    var found = yield Docker.run (project.path, {
                        "volume", "ls", "--quiet",
                        "--filter", "label=com.docker.compose.project=" + project_name,
                        "--filter", "label=com.docker.compose.volume=" + volume,
                    });
                    foreach (unowned string name in Utils.split_lines (found.stdout_text)) {
                        volumes += name;
                    }
                }
                removal.volumes = volumes;
            } finally {
                overlay.remove ();
            }
            return removal;
        }

        /*
         * Removes the service: the container first, because once the service is gone from the
         * files Compose no longer knows it. Nothing else changes if that fails. Volumes that
         * cannot be deleted do not stop it, and are described in `problems`.
         */
        public async void remove (CommandRunner runner, ServiceRemoval removal, bool delete_data,
                                  out string[] problems) throws Error {
            string[] found = {};
            problems = found;
            var service = removal.service;
            if (!(yield runner.run (Docker.compose_args ({ "rm", "--stop", "--force", "--volumes", service })))) {
                throw new IOError.FAILED (_("Could not remove the “%s” container").printf (service));
            }
            if (delete_data) {
                foreach (unowned string volume in removal.volumes) {
                    try {
                        if (!(yield runner.run ({ "volume", "rm", volume }))) {
                            found += _("Could not delete the volume %s").printf (volume);
                        }
                    } catch (IOError.CANCELLED e) {
                        throw e;
                    } catch (Error e) {
                        found += e.message;
                    }
                }
            }
            problems = found;
            try {
                apply (removal);
            } catch (Error e) {
                throw new IOError.FAILED (_("Could not remove “%s”: %s").printf (service, e.message));
            }
        }

        /* Changes the files: the include first, so the compose file never points to a missing file. */
        private void apply (ServiceRemoval removal) throws Error {
            File.new_for_path (removal.main_path).replace_contents (removal.new_main.data, null, false, FileCreateFlags.NONE, null);
            try {
                removal.service_file.delete ();
            } catch (IOError.NOT_FOUND e) {
            }
            if (removal.new_env != null) {
                // replace_contents keeps the permissions of .env.
                removal.env_file.replace_contents (removal.new_env.data, null, false, FileCreateFlags.NONE, null);
            }
        }
    }
}
