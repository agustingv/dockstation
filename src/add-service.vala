namespace DockStation {
    /*
     * Adds a service to a project without rewriting its compose file: the service
     * goes to its own compose.<service>.yaml, which the compose file includes.
     */
    namespace ServiceAdder {
        /*
         * Adds `path` to the top-level `include:` list of a compose file, creating the
         * list if needed. Returns null if the list is written in a form this cannot edit.
         */
        public string? add_include (string text, string path) {
            string[] lines = text.split ("\n");

            int include_line = -1;
            int name_line = -1;
            int services_line = -1;
            for (int i = 0; i < lines.length; i++) {
                if (include_line < 0 && lines[i].has_prefix ("include:")) {
                    var rest = lines[i].substring ("include:".length).strip ();
                    if (rest != "" && !rest.has_prefix ("#")) {
                        return null;  // A flow list such as `include: [a.yaml]`
                    }
                    include_line = i;
                } else if (name_line < 0 && lines[i].has_prefix ("name:")) {
                    name_line = i;
                } else if (services_line < 0 && lines[i].has_prefix ("services:")) {
                    services_line = i;
                }
            }

            string[] insert;
            int at;
            if (include_line >= 0) {
                // Append after the last item, with the indentation the list already uses.
                at = include_line + 1;
                string indent = "  ";
                bool indent_found = false;
                for (int i = include_line + 1; i < lines.length; i++) {
                    unowned string line = lines[i];
                    var stripped = line.strip ();
                    if (stripped == "" || stripped.has_prefix ("#")) {
                        continue;
                    }
                    if (!line.has_prefix (" ") && !line.has_prefix ("\t") && !line.has_prefix ("-")) {
                        break;  // The next top-level key
                    }
                    if (!indent_found && stripped.has_prefix ("-")) {
                        indent = line.substring (0, line.index_of ("-"));
                        indent_found = true;
                    }
                    at = i + 1;
                }
                insert = { indent + "- " + path };
            } else if (name_line >= 0) {
                at = name_line + 1;
                insert = { "", "include:", "  - " + path };
                if (at < lines.length && lines[at].strip () != "") {
                    insert += "";
                }
            } else {
                at = services_line >= 0 ? services_line : 0;
                insert = { "include:", "  - " + path, "" };
            }

            string[] result = {};
            for (int i = 0; i < lines.length; i++) {
                if (i == at) {
                    foreach (unowned string line in insert) {
                        result += line;
                    }
                }
                result += lines[i];
            }
            if (at >= lines.length) {
                foreach (unowned string line in insert) {
                    result += line;
                }
            }
            return string.joinv ("\n", result);
        }

        /* A relative path that stays inside the project: no leading "/", no ".." segments. */
        public bool is_safe_relative_path (string path) {
            if (path == "" || path.has_prefix ("/")) {
                return false;
            }
            foreach (unowned string part in path.split ("/")) {
                if (part == "..") {
                    return false;
                }
            }
            return Regex.match_simple ("^[A-Za-z0-9._/-]+$", path);
        }

        /* Describes what is wrong with an option's value, or returns null. */
        public string? option_problem (ServiceOption option, string value) {
            switch (option.option_type) {
                case ServiceOptionType.SERVICE:
                    if (value == "") {
                        return _("The project has no services for “%s”").printf (option.title);
                    }
                    return null;
                case ServiceOptionType.FOLDER:
                    if (!is_safe_relative_path (value)) {
                        return _("“%s” must be a folder inside the project, such as “public”").printf (option.title);
                    }
                    return null;
                default:
                    // Values end up in YAML: keep them to characters that never need quoting.
                    if (!Regex.match_simple ("^[A-Za-z0-9._/:@-]+$", value)) {
                        return _("“%s” cannot be empty or contain spaces or quotes").printf (option.title);
                    }
                    return null;
            }
        }

        /* Values for the template's placeholders. */
        public HashTable<string, string> placeholders (ServiceTemplate template, string service,
                                                       ServiceVersion version, HashTable<string, string> options) {
            var vars = new HashTable<string, string> (str_hash, str_equal);
            version.vars.foreach ((key, value) => vars[key] = value);
            options.foreach ((key, value) => vars[key] = value);
            var password_var = ServiceTemplate.env_prefix (service) + "_PASSWORD";
            vars["SERVICE"] = service;
            vars["VERSION"] = version.name;
            vars["PREFIX"] = ServiceTemplate.env_prefix (service);
            vars["VOLUME"] = ServiceTemplate.volume_name (service);
            vars["PASSWORD"] = Utils.random_secret (24);
            vars["PASSWORD_VAR"] = password_var;
            vars["PASSWORD_REF"] = "${" + password_var + "}";
            return vars;
        }

        /* Creates `dir` and any missing parents, remembering them so they can be removed again. */
        private void make_directories (File dir, GenericArray<File> created) throws Error {
            File[] missing = {};
            for (var current = dir; current != null && !current.query_exists (); current = current.get_parent ()) {
                missing += current;
            }
            for (int i = missing.length - 1; i >= 0; i--) {
                missing[i].make_directory ();
                created.add (missing[i]);
            }
        }

        /*
         * Writes the service's compose file and starter files, includes the compose file from
         * the project's one and appends its settings to .env. The result is checked with
         * `docker compose config` before the project's compose file is changed; on failure,
         * every change is undone. Existing files are never overwritten.
         */
        public async void add (Project project, ServiceTemplate template, string service,
                               ServiceVersion version, int host_port, HashTable<string, string> options) throws Error {
            var files = project.compose_files ();
            if (files.length == 0 || !FileUtils.test (files[0], FileTest.IS_REGULAR)) {
                throw new IOError.NOT_FOUND (_("The project has no compose file"));
            }
            var main_path = files[0];
            var main_name = Path.get_basename (main_path);
            var base_dir = File.new_for_path (Path.get_dirname (main_path));
            var file_name = "compose.%s.yaml".printf (service);
            var service_file = base_dir.get_child (file_name);

            string main_text;
            FileUtils.get_contents (main_path, out main_text);
            var new_main = add_include (main_text, file_name);
            if (new_main == null) {
                throw new IOError.NOT_SUPPORTED (
                    _("The include list in %s cannot be edited automatically").printf (main_name));
            }

            foreach (var option in template.options) {
                var problem = option_problem (option, options[option.key] ?? "");
                if (problem != null) {
                    throw new IOError.INVALID_ARGUMENT (problem);
                }
            }

            // Render everything first: a template error must not leave anything behind.
            var vars = placeholders (template, service, version, options);
            var compose_text = template.render_compose (vars, service, host_port);
            var env_addition = template.render_env (vars, service, host_port);

            var env_file = File.new_for_path (Path.build_filename (project.path, ".env"));
            string env_text = "";
            bool env_existed = env_file.query_exists ();
            if (env_existed) {
                FileUtils.get_contents (env_file.get_path (), out env_text);
            }
            var existing_keys = Utils.env_keys (env_text);
            foreach (unowned string key in Utils.env_keys (env_addition)) {
                if (key in existing_keys) {
                    throw new IOError.EXISTS (_("The variable %s is already defined in .env").printf (key));
                }
            }

            // Folders the user chose that already have content: starter files must not mix with it.
            File[] filled_folders = {};
            foreach (var option in template.options) {
                if (option.option_type == ServiceOptionType.FOLDER) {
                    var folder = base_dir.resolve_relative_path (options[option.key]);
                    if (folder.query_exists () && !Utils.is_directory_empty (folder)) {
                        filled_folders += folder;
                    }
                }
            }

            // Starter files never replace existing files.
            File[] starter_targets = {};
            string[] starter_texts = {};
            for (int i = 0; i < template.file_paths.length; i++) {
                var path = ServiceTemplate.substitute (template.file_paths[i], vars);
                if (!is_safe_relative_path (path)) {
                    throw new ServiceTemplateError.INVALID (_("Invalid file path “%s”").printf (path));
                }
                var target = base_dir.resolve_relative_path (path);
                bool in_filled_folder = false;
                foreach (var folder in filled_folders) {
                    in_filled_folder |= target.has_prefix (folder);
                }
                if (!target.query_exists () && !in_filled_folder) {
                    starter_targets += target;
                    starter_texts += ServiceTemplate.substitute (template.file_contents[i], vars);
                }
            }

            // Compose silently merges volumes with the same name, so the services would share their data.
            if (template.uses_volume) {
                var volume = ServiceTemplate.volume_name (service);
                var volumes = yield Docker.run (project.path, Docker.compose_args ({ "config", "--volumes" }));
                if (volumes.success && volume in Utils.split_lines (volumes.stdout_text)) {
                    throw new IOError.EXISTS (_("The project already has a volume named %s").printf (volume));
                }
            }

            // The service file must exist for the include to be checked.
            FileOutputStream stream;
            try {
                stream = service_file.create (FileCreateFlags.NONE);
            } catch (IOError.EXISTS e) {
                throw new IOError.EXISTS (_("The file %s already exists").printf (file_name));
            }

            var created_dirs = new GenericArray<File> ();
            var created_files = new GenericArray<File> ();
            bool env_written = false;
            string? copy = null;
            try {
                stream.write_all (compose_text.data, null);
                stream.close ();

                // Folders the service mounts; Docker would otherwise create them owned by root.
                foreach (var option in template.options) {
                    if (option.option_type == ServiceOptionType.FOLDER) {
                        make_directories (base_dir.resolve_relative_path (options[option.key]), created_dirs);
                    }
                }
                for (int i = 0; i < starter_targets.length; i++) {
                    make_directories (starter_targets[i].get_parent (), created_dirs);
                    var starter = starter_targets[i].create (FileCreateFlags.NONE);
                    created_files.add (starter_targets[i]);
                    starter.write_all (starter_texts[i].data, null);
                    starter.close ();
                }

                if (env_addition != "") {
                    var separator = env_text == "" || env_text.has_suffix ("\n") ? "" : "\n";
                    var text = env_text + separator + "\n# " + service + "\n" + env_addition;
                    // replace_contents keeps the permissions of an existing .env; a new one is private.
                    env_file.replace_contents (text.data, null, false,
                                               env_existed ? FileCreateFlags.NONE : FileCreateFlags.PRIVATE, null);
                    env_written = true;
                }

                copy = Utils.write_hidden_copy (main_path, new_main);
                string[] args = {};
                foreach (unowned string file in files) {
                    args += "-f";
                    args += file == main_path ? copy : file;
                }
                args += "config";
                args += "--quiet";
                var result = yield Docker.run (project.path, Docker.compose_args (args));
                if (!result.success) {
                    var message = result.stderr_text.strip ()
                        .replace (copy, main_path)
                        .replace (Path.get_basename (copy), main_name);
                    throw new IOError.FAILED (message);
                }

                File.new_for_path (main_path).replace_contents (new_main.data, null, false, FileCreateFlags.NONE, null);
            } catch (Error e) {
                FileUtils.unlink (service_file.get_path ());
                foreach (var file in created_files) {
                    FileUtils.unlink (file.get_path ());
                }
                for (int i = (int) created_dirs.length - 1; i >= 0; i--) {
                    DirUtils.remove (created_dirs[i].get_path ());
                }
                if (env_written) {
                    try {
                        if (env_existed) {
                            env_file.replace_contents (env_text.data, null, false, FileCreateFlags.NONE, null);
                        } else {
                            env_file.delete ();
                        }
                    } catch (Error restore_error) {
                        warning ("Could not restore .env: %s", restore_error.message);
                    }
                }
                throw e;
            } finally {
                if (copy != null) {
                    FileUtils.unlink (copy);
                }
            }
        }
    }

    public class AddServiceDialog : Adw.Dialog {
        public signal void added (string service, bool start);

        private Project project;
        private string[] used_names;
        private ServiceTemplate[] templates;

        private Adw.ComboRow template_row;
        private Adw.EntryRow name_row;
        private Adw.ComboRow version_row;
        private Gtk.StringList version_model;
        private Adw.SwitchRow publish_row;
        private Adw.SpinRow port_row;
        private Adw.SwitchRow start_row;
        private Adw.PreferencesGroup options_group;
        private Gtk.Button add_button;
        private bool adding = false;

        // Rows of the selected service's own options, keyed by placeholder name.
        private Gtk.Widget[] option_rows = {};
        private HashTable<string, Gtk.Widget> option_widgets = new HashTable<string, Gtk.Widget> (str_hash, str_equal);
        // The option defaults for the current service name, to update rows the user has not changed.
        private HashTable<string, string> option_defaults = new HashTable<string, string> (str_hash, str_equal);

        public AddServiceDialog (Project project, string[] used_names) {
            this.project = project;
            this.used_names = used_names;
            string[] problems;
            templates = ServiceTemplates.load_all (out problems);

            title = _("Add Service");
            content_width = 520;

            var cancel_button = new Gtk.Button.with_mnemonic (_("_Cancel"));
            cancel_button.clicked.connect (() => close ());

            add_button = new Gtk.Button.with_mnemonic (_("_Add"));
            add_button.add_css_class ("suggested-action");
            add_button.clicked.connect (() => add.begin ());

            var header = new Adw.HeaderBar () {
                show_start_title_buttons = false,
                show_end_title_buttons = false,
            };
            header.pack_start (cancel_button);
            header.pack_end (add_button);

            var names = new Gtk.StringList (null);
            foreach (var template in templates) {
                names.append (template.name);
            }
            template_row = new Adw.ComboRow () {
                title = _("Service"),
                model = names,
            };
            template_row.notify["selected"].connect (on_template_changed);

            var template_group = new Adw.PreferencesGroup ();
            template_group.add (template_row);
            if (problems.length > 0) {
                template_group.description = _("Some custom services could not be loaded:") + "\n" + string.joinv ("\n", problems);
            }

            name_row = new Adw.EntryRow () { title = _("Service Name") };
            name_row.changed.connect (on_name_changed);
            name_row.entry_activated.connect (() => {
                if (add_button.sensitive) {
                    add.begin ();
                }
            });

            version_model = new Gtk.StringList (null);
            version_row = new Adw.ComboRow () {
                title = _("Version"),
                model = version_model,
            };
            version_row.notify["selected"].connect (update_version_description);

            publish_row = new Adw.SwitchRow () {
                title = _("Publish Port"),
                subtitle = _("Make the service reachable from this computer"),
            };
            port_row = new Adw.SpinRow.with_range (1, 65535, 1) {
                title = _("Host Port"),
                subtitle = _("Only reachable at localhost"),
            };
            publish_row.bind_property ("active", port_row, "sensitive", BindingFlags.SYNC_CREATE);

            options_group = new Adw.PreferencesGroup () { title = _("Options") };
            options_group.add (name_row);
            options_group.add (version_row);
            options_group.add (publish_row);
            options_group.add (port_row);

            start_row = new Adw.SwitchRow () {
                title = _("Start After Adding"),
                subtitle = _("Pull the image and start the service"),
                active = true,
            };
            var start_group = new Adw.PreferencesGroup ();
            start_group.add (start_row);

            var page = new Adw.PreferencesPage ();
            page.add (template_group);
            page.add (options_group);
            page.add (start_group);

            var toolbar = new Adw.ToolbarView () { content = page };
            toolbar.add_top_bar (header);
            child = toolbar;
            focus_widget = template_row;

            on_template_changed ();
        }

        private ServiceTemplate? selected_template {
            get { return templates.length > 0 ? templates[template_row.selected] : null; }
        }

        private ServiceVersion selected_version {
            get { return selected_template.versions[version_row.selected]; }
        }

        private void on_template_changed () {
            var template = selected_template;
            if (template == null) {
                add_button.sensitive = false;
                return;
            }
            template_row.subtitle = template.description;

            string[] version_names = {};
            foreach (var version in template.versions) {
                version_names += version.name;
            }
            version_model.splice (0, version_model.get_n_items (), version_names);
            version_row.selected = 0;
            version_row.visible = template.versions.length > 1;
            update_version_description ();

            publish_row.visible = template.can_publish;
            port_row.visible = template.can_publish;
            publish_row.active = template.publish_by_default;
            port_row.value = template.default_host_port;

            build_option_rows (template);
            // Also fills the option rows' defaults, which may depend on the name.
            name_row.text = free_name (template.default_service);
            on_name_changed ();
        }

        private void update_version_description () {
            var template = selected_template;
            version_row.subtitle = template != null && version_row.selected < template.versions.length
                ? selected_version.description : "";
        }

        private void build_option_rows (ServiceTemplate template) {
            foreach (var row in option_rows) {
                options_group.remove (row);
            }
            option_rows = {};
            option_widgets.remove_all ();
            option_defaults.remove_all ();

            foreach (var option in template.options) {
                Gtk.Widget row;
                switch (option.option_type) {
                    case ServiceOptionType.SERVICE:
                        var combo = new Adw.ComboRow () {
                            title = option.title,
                            subtitle = option.subtitle,
                            model = new Gtk.StringList (used_names),
                        };
                        row = combo;
                        break;
                    case ServiceOptionType.FOLDER:
                        var entry = new Adw.EntryRow () { title = option.title };
                        var browse = new Gtk.Button.from_icon_name ("folder-open-symbolic") {
                            tooltip_text = _("Choose Folder"),
                            valign = Gtk.Align.CENTER,
                        };
                        browse.add_css_class ("flat");
                        browse.clicked.connect (() => choose_folder.begin (entry));
                        entry.add_suffix (browse);
                        entry.changed.connect (update_state);
                        row = entry;
                        break;
                    default:
                        var entry = new Adw.EntryRow () { title = option.title };
                        entry.changed.connect (update_state);
                        row = entry;
                        break;
                }
                if (option.subtitle != "") {
                    row.tooltip_text = option.subtitle;
                }
                options_group.add (row);
                option_rows += row;
                option_widgets[option.key] = row;
            }
        }

        /* Text options follow the service name, as long as the user has not changed them. */
        private void on_name_changed () {
            var template = selected_template;
            if (template == null) {
                return;
            }
            var vars = new HashTable<string, string> (str_hash, str_equal);
            vars["SERVICE"] = service_name;
            foreach (var option in template.options) {
                var entry = option_widgets[option.key] as Adw.EntryRow;
                if (entry == null) {
                    continue;
                }
                string value;
                try {
                    value = ServiceTemplate.substitute (option.default_value, vars);
                } catch (Error e) {
                    value = option.default_value;
                }
                var previous = option_defaults[option.key];
                if (previous == null || entry.text == previous) {
                    entry.text = value;
                }
                option_defaults[option.key] = value;
            }
            update_state ();
        }

        private async void choose_folder (Adw.EntryRow entry) {
            var base_dir = File.new_for_path (project.path);
            var dialog = new Gtk.FileDialog () {
                title = _("Choose Folder"),
                initial_folder = base_dir,
            };
            File folder;
            try {
                folder = yield dialog.select_folder ((Gtk.Window) get_root (), null);
            } catch (Error e) {
                return;  // Dismissed
            }
            var relative = base_dir.get_relative_path (folder);
            if (relative == null) {
                var alert = new Adw.AlertDialog (_("Choose a Folder in the Project"),
                                                 _("The folder must be inside %s.").printf (Utils.home_relative (project.path)));
                alert.add_response ("close", _("_Close"));
                alert.present (this);
                return;
            }
            entry.text = relative;
        }

        /* `base_name`, or `base_name-2`, `-3`… if the project already has that service. */
        private string free_name (string base_name) {
            var name = base_name;
            for (int i = 2; name in used_names; i++) {
                name = "%s-%d".printf (base_name, i);
            }
            return name;
        }

        private string service_name {
            owned get { return name_row.text.strip (); }
        }

        private HashTable<string, string> option_values () {
            var values = new HashTable<string, string> (str_hash, str_equal);
            option_widgets.foreach ((key, widget) => {
                if (widget is Adw.ComboRow) {
                    var combo = (Adw.ComboRow) widget;
                    values[key] = ((Gtk.StringList) combo.model).get_string (combo.selected) ?? "";
                } else {
                    values[key] = ((Adw.EntryRow) widget).text.strip ();
                }
            });
            return values;
        }

        private string? name_problem () {
            var name = service_name;
            if (name != "" && !ServiceTemplate.is_valid_service_name (name)) {
                return _("Use lowercase letters, digits, “-” and “_” for the name, starting with a letter");
            }
            if (name in used_names) {
                return _("The project already has a service with this name");
            }
            return null;
        }

        private string? option_problem () {
            var values = option_values ();
            foreach (var option in selected_template.options) {
                var problem = ServiceAdder.option_problem (option, values[option.key]);
                if (problem != null) {
                    return problem;
                }
            }
            return null;
        }

        private void update_state () {
            if (selected_template == null) {
                return;
            }
            var name_error = name_problem ();
            if (name_error != null) {
                name_row.add_css_class ("error");
            } else {
                name_row.remove_css_class ("error");
            }
            var problem = name_error ?? option_problem ();
            options_group.description = problem;
            add_button.sensitive = !adding && service_name != "" && problem == null;
        }

        private async void add () {
            var name = service_name;
            var start = start_row.active;
            adding = true;
            update_state ();
            try {
                yield ServiceAdder.add (project, selected_template, name, selected_version,
                                        publish_row.visible && publish_row.active ? (int) port_row.value : 0,
                                        option_values ());
            } catch (Error e) {
                adding = false;
                update_state ();
                var alert = new Adw.AlertDialog (_("Could Not Add the Service"), e.message);
                alert.add_response ("close", _("_Close"));
                alert.present (this);
                return;
            }
            added (name, start);
            close ();
        }
    }
}
