namespace DockStation {
    public class NewProjectDialog : Adw.Dialog {
        public signal void created (Project project, bool start);

        private ProjectStore store;
        private Template[] templates;
        private File parent_folder;

        private Adw.ToastOverlay toast_overlay;
        private Adw.EntryRow name_row;
        private Adw.ActionRow location_row;
        private Adw.ComboRow template_row;
        private Adw.SpinRow port_row;
        private Adw.ComboRow php_row;
        private Gtk.StringList php_model;
        private Adw.SwitchRow composer_row;
        private Adw.SwitchRow start_row;
        private Gtk.Button create_button;

        public NewProjectDialog (ProjectStore store) {
            this.store = store;
            templates = Templates.all ();
            parent_folder = default_parent_folder ();

            title = _("New Project");
            content_width = 520;

            var cancel_button = new Gtk.Button.with_mnemonic (_("_Cancel"));
            cancel_button.clicked.connect (() => close ());

            create_button = new Gtk.Button.with_mnemonic (_("C_reate"));
            create_button.add_css_class ("suggested-action");
            create_button.clicked.connect (create);

            var header = new Adw.HeaderBar () {
                show_start_title_buttons = false,
                show_end_title_buttons = false,
            };
            header.pack_start (cancel_button);
            header.pack_end (create_button);

            // General
            name_row = new Adw.EntryRow () { title = _("Project Name") };
            name_row.changed.connect (update_state);
            name_row.entry_activated.connect (() => {
                if (create_button.sensitive) {
                    create ();
                }
            });

            var browse_button = new Gtk.Button.from_icon_name ("folder-open-symbolic") {
                tooltip_text = _("Choose Location"),
                valign = Gtk.Align.CENTER,
            };
            browse_button.add_css_class ("flat");
            browse_button.clicked.connect (choose_folder);

            location_row = new Adw.ActionRow () {
                title = _("Location"),
                activatable_widget = browse_button,
                subtitle_selectable = true,
            };
            location_row.add_suffix (browse_button);

            var general_group = new Adw.PreferencesGroup ();
            general_group.add (name_row);
            general_group.add (location_row);

            // Template
            var names = new Gtk.StringList (null);
            foreach (var template in templates) {
                names.append (template.name);
            }
            template_row = new Adw.ComboRow () {
                title = _("Template"),
                model = names,
            };
            template_row.notify["selected"].connect (on_template_changed);

            port_row = new Adw.SpinRow.with_range (1, 65535, 1) {
                title = _("Host Port"),
                subtitle = _("Port published on this computer"),
            };

            php_model = new Gtk.StringList (null);
            php_row = new Adw.ComboRow () {
                title = _("PHP Version"),
                model = php_model,
            };

            composer_row = new Adw.SwitchRow () { title = _("Install Composer") };

            var template_group = new Adw.PreferencesGroup () { title = _("Template") };
            template_group.add (template_row);
            template_group.add (php_row);
            template_group.add (composer_row);
            template_group.add (port_row);

            // Options
            start_row = new Adw.SwitchRow () {
                title = _("Start After Creating"),
                subtitle = _("Pull or build the images and start the services"),
            };
            var options_group = new Adw.PreferencesGroup ();
            options_group.add (start_row);

            var page = new Adw.PreferencesPage ();
            page.add (general_group);
            page.add (template_group);
            page.add (options_group);

            var toolbar = new Adw.ToolbarView () { content = page };
            toolbar.add_top_bar (header);

            toast_overlay = new Adw.ToastOverlay () { child = toolbar };
            child = toast_overlay;
            focus_widget = name_row;

            on_template_changed ();
        }

        private static File default_parent_folder () {
            var projects = File.new_for_path (Path.build_filename (Environment.get_home_dir (), "Projects"));
            if (projects.query_file_type (FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                return projects;
            }
            return File.new_for_path (Environment.get_home_dir ());
        }

        private Template selected_template {
            get { return templates[template_row.selected]; }
        }

        private void on_template_changed () {
            var template = selected_template;
            template_row.subtitle = template.description;
            port_row.visible = template.uses_port;
            update_php_versions (template);
            update_composer (template);
            if (template.uses_port) {
                port_row.value = template.default_port;
            }
            update_state ();
        }

        private void update_php_versions (Template template) {
            php_row.visible = template.uses_php;
            if (!template.uses_php) {
                return;
            }

            // Keep the user's choice when switching between PHP templates, if still supported.
            string? previous = php_model.get_n_items () > 0 ? selected_php_version () : null;
            php_model.splice (0, php_model.get_n_items (), template.php_versions);

            uint selected = 0;
            for (uint i = 0; i < template.php_versions.length; i++) {
                if (template.php_versions[i] == (previous ?? template.default_php_version)) {
                    selected = i;
                    break;
                }
                if (template.php_versions[i] == template.default_php_version) {
                    selected = i;
                }
            }
            php_row.selected = selected;
            php_row.subtitle = template.php_note;
        }

        private void update_composer (Template template) {
            composer_row.visible = template.composer != ComposerSupport.NONE;
            composer_row.active = template.composer_default;
            composer_row.sensitive = template.composer == ComposerSupport.OPTIONAL;
            switch (template.composer) {
                case ComposerSupport.INCLUDED:
                    composer_row.subtitle = _("Already included in the %s image").printf (template.name);
                    break;
                case ComposerSupport.REQUIRED:
                    composer_row.subtitle = _("Required by %s").printf (template.name);
                    break;
                default:
                    composer_row.subtitle = _("Add Composer to the image to manage PHP dependencies");
                    break;
            }
        }

        /* Whether the generated Dockerfile must install Composer itself. */
        private bool dockerfile_installs_composer () {
            switch (selected_template.composer) {
                case ComposerSupport.REQUIRED:
                    return true;
                case ComposerSupport.OPTIONAL:
                    return composer_row.active;
                default:
                    return false;
            }
        }

        private string selected_php_version () {
            return php_model.get_string (php_row.selected) ?? selected_template.default_php_version;
        }

        private File target_folder () {
            return parent_folder.get_child (Utils.slugify (name_row.text));
        }

        private void update_state () {
            var slug = Utils.slugify (name_row.text);
            bool valid = slug != "";
            string? problem = null;

            if (valid) {
                var target = target_folder ();
                if (store.find_by_path (target.get_path ()) != null) {
                    problem = _("This project is already in the list");
                } else if (!Utils.is_directory_empty (target)) {
                    problem = _("The folder already exists and is not empty");
                }
            }

            if (problem != null) {
                name_row.add_css_class ("error");
                location_row.subtitle = problem;
            } else {
                name_row.remove_css_class ("error");
                location_row.subtitle = Utils.home_relative (valid ? target_folder ().get_path () : parent_folder.get_path ());
            }
            create_button.sensitive = valid && problem == null;
        }

        private void choose_folder () {
            var dialog = new Gtk.FileDialog () {
                title = _("Choose Location"),
                initial_folder = parent_folder,
            };
            dialog.select_folder.begin ((Gtk.Window) get_root (), null, (obj, res) => {
                try {
                    parent_folder = dialog.select_folder.end (res);
                    update_state ();
                } catch (Error e) {
                    // Dismissed by the user.
                }
            });
        }

        private void create () {
            var name = name_row.text.strip ();
            var target = target_folder ();

            var vars = new HashTable<string, string> (str_hash, str_equal);
            vars["NAME"] = name;
            vars["NAME_HTML"] = Markup.escape_text (name);
            vars["SLUG"] = Utils.slugify (name);
            vars["PORT"] = ((int) port_row.value).to_string ();
            if (selected_template.uses_php) {
                vars["PHP_VERSION"] = selected_php_version ();
            }
            vars["COMPOSER_INSTALL"] = dockerfile_installs_composer () ? Templates.COMPOSER_DOCKERFILE : "";
            vars["PASSWORD"] = Utils.random_secret (24);
            vars["UID"] = ((uint) Posix.getuid ()).to_string ();
            vars["GID"] = ((uint) Posix.getgid ()).to_string ();

            try {
                selected_template.write_to (target, vars);
            } catch (Error e) {
                toast_overlay.add_toast (new Adw.Toast (e.message));
                return;
            }

            created (new Project (name, target.get_path ()), start_row.active);
            close ();
        }
    }
}
