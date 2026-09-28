namespace DockStation {
    public class ProjectView : Adw.BreakpointBin {
        public Project project { get; construct; }

        public signal void toast (string message);
        public signal void remove_requested ();
        /* Emitted after the project was deleted from disk; the view must be discarded. */
        public signal void deleted ();
        public signal void containers_changed ();

        private const string[] COMPOSE_ACTIONS = { "up", "stop", "restart", "down", "pull", "build", "down-volumes", "delete" };
        private const string PS_FORMAT = "{{.Service}}\t{{.Name}}\t{{.State}}\t{{.Status}}\t{{.Ports}}";

        private Cancellable cancellable = new Cancellable ();
        private SimpleActionGroup actions;
        private ulong status_handler = 0;
        private bool busy = false;

        private Adw.ViewStack stack;
        private Adw.ViewStackPage output_stack_page;
        private Adw.Spinner spinner;

        // Services page
        private Adw.ActionRow status_row;
        private Adw.PreferencesGroup services_group;
        private HashTable<string, ServiceRow> service_rows;
        private string[] service_names = {};
        private bool config_loaded = false;
        private bool refreshing_services = false;
        private bool config_reload_pending = false;

        // Editor page
        private string[] editor_files = {};
        private Gtk.StringList file_model;
        private Gtk.DropDown file_dropdown;
        private Gtk.TextBuffer editor_buffer;
        private Gtk.TextView editor_view;
        private Adw.Banner editor_banner;
        private uint current_file_index = 0;
        private string? editing_path = null;
        private bool loading_file = false;
        private bool switching_file = false;
        private bool dirty = false;

        // Logs page
        private LogView logs_view;
        private Gtk.StringList logs_services_model;
        private Gtk.DropDown logs_service_dropdown;
        private Gtk.ToggleButton timestamps_toggle;
        private Cancellable? logs_cancellable = null;
        private bool logs_started = false;
        private bool updating_logs_model = false;

        // Output page
        private LogView output_view;

        public ProjectView (Project project) {
            Object (project: project);
        }

        public bool has_unsaved_changes {
            get { return dirty; }
        }

        public string editing_file_name {
            owned get { return editing_path != null ? Path.get_basename (editing_path) : ""; }
        }

        construct {
            width_request = 360;
            height_request = 300;
            service_rows = new HashTable<string, ServiceRow> (str_hash, str_equal);

            setup_actions ();
            build_ui ();

            status_handler = project.status_changed.connect (update_status_row);
            update_status_row ();

            reload_editor_files ();
            reload ();
        }

        /* Must be called before the view is discarded, to stop background processes. */
        public void shutdown () {
            cancellable.cancel ();
            if (logs_cancellable != null) {
                logs_cancellable.cancel ();
            }
            if (status_handler != 0) {
                project.disconnect (status_handler);
                status_handler = 0;
            }
        }

        public void reload () {
            refresh_services.begin (true);
        }

        /* ---------------------------------------------------------------- actions */

        private void setup_actions () {
            actions = new SimpleActionGroup ();

            add_compose_action ("up", { "up", "--detach" }, _("Project started"), _("Could not start the project"));
            add_compose_action ("stop", { "stop" }, _("Project stopped"), _("Could not stop the project"));
            add_compose_action ("restart", { "restart" }, _("Project restarted"), _("Could not restart the project"));
            add_compose_action ("down", { "down" }, _("Containers removed"), _("Could not take the project down"));
            add_compose_action ("pull", { "pull" }, _("Images pulled"), _("Could not pull images"));
            add_compose_action ("build", { "build" }, _("Images built"), _("Could not build images"));

            add_simple_action ("down-volumes", () => confirm_down_volumes.begin ());
            add_simple_action ("open-folder", open_folder);
            add_simple_action ("remove", () => remove_requested ());
            add_simple_action ("delete", () => delete_project.begin ());
            add_simple_action ("save-file", save_file);
            add_simple_action ("revert-file", () => load_file_at (current_file_index));
            add_simple_action ("validate", () => validate.begin (false));

            insert_action_group ("project", actions);

            var shortcuts = new Gtk.ShortcutController ();
            shortcuts.add_shortcut (new Gtk.Shortcut (
                Gtk.ShortcutTrigger.parse_string ("<Control>s"),
                new Gtk.NamedAction ("project.save-file")
            ));
            add_controller (shortcuts);
        }

        private delegate void ActionFunc ();

        private void add_simple_action (string name, owned ActionFunc func) {
            var action = new SimpleAction (name, null);
            action.activate.connect (() => func ());
            actions.add_action (action);
        }

        private void add_compose_action (string name, owned string[] args, string success, string failure) {
            var action = new SimpleAction (name, null);
            action.activate.connect (() => run_compose.begin (args, success, failure));
            actions.add_action (action);
        }

        private void set_action_enabled (string name, bool enabled) {
            ((SimpleAction) actions.lookup_action (name)).set_enabled (enabled);
        }

        private string[] compose_args (string[] args) {
            string[] result = { "compose", "--ansi", "never", "--progress", "plain" };
            foreach (unowned string arg in args) {
                result += arg;
            }
            return result;
        }

        private void set_busy (bool value) {
            busy = value;
            spinner.visible = value;
            output_stack_page.needs_attention = value;
            foreach (unowned string name in COMPOSE_ACTIONS) {
                set_action_enabled (name, !value);
            }
            service_rows.foreach ((name, row) => row.set_actions_sensitive (!value));
        }

        /* Returns true if the command ran and exited successfully. */
        public async bool run_compose (owned string[] args, string success_message, string failure_message) {
            if (busy) {
                return false;
            }
            if (project.find_compose_file () == null) {
                toast (_("No compose file found in %s").printf (Utils.home_relative (project.path)));
                return false;
            }

            set_busy (true);
            output_view.append ("$ docker compose %s\n".printf (string.joinv (" ", args)));
            bool success = false;
            try {
                int status = yield Docker.stream (project.path, compose_args (args), (line) => {
                    output_view.append (line + "\n");
                }, cancellable);

                success = status == 0;
                if (success) {
                    output_view.append ("✔ " + _("Done") + "\n\n");
                    toast (success_message);
                } else {
                    output_view.append ("✘ " + _("Exited with status %d").printf (status) + "\n\n");
                    toast (failure_message);
                    stack.visible_child_name = "output";
                }
            } catch (IOError.CANCELLED e) {
                return false;
            } catch (Error e) {
                output_view.append (e.message + "\n\n");
                toast (failure_message);
                stack.visible_child_name = "output";
            }
            set_busy (false);

            containers_changed ();
            yield refresh_services (false);
            if (logs_started) {
                restart_logs ();
            }
            return success;
        }

        private async void confirm_down_volumes () {
            var dialog = new Adw.AlertDialog (
                _("Remove Containers and Volumes?"),
                _("This runs “docker compose down --volumes”. All data stored in the project’s named volumes will be permanently deleted.")
            );
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("remove", _("_Remove"));
            dialog.set_response_appearance ("remove", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";

            if ((yield dialog.choose (this, null)) == "remove") {
                yield run_compose ({ "down", "--volumes" }, _("Containers and volumes removed"), _("Could not take the project down"));
            }
        }

        private async void delete_project () {
            bool has_compose_file = project.find_compose_file () != null;

            var containers_row = new Adw.SwitchRow () {
                title = _("Remove Containers and Volumes"),
                subtitle = _("Also deletes locally built images and all data in the volumes, such as databases"),
                active = has_compose_file,
                sensitive = has_compose_file,
            };
            var folder_row = new Adw.SwitchRow () {
                title = _("Move Folder to Trash"),
                subtitle = Utils.home_relative (project.path),
                active = true,
            };
            var options = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
            options.add_css_class ("boxed-list");
            options.append (containers_row);
            options.append (folder_row);

            var dialog = new Adw.AlertDialog (
                _("Delete “%s”?").printf (project.name),
                _("The project will be removed from the list. Data in volumes cannot be recovered.")
            ) {
                extra_child = options,
            };
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("delete", _("_Delete"));
            dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";

            if ((yield dialog.choose (this, null)) != "delete") {
                return;
            }
            bool remove_containers = containers_row.active;
            bool trash_folder = folder_row.active;

            // Stop everything first: a failure here must leave the folder untouched.
            if (remove_containers) {
                bool removed = yield run_compose (
                    { "down", "--volumes", "--remove-orphans", "--rmi", "local" },
                    _("Containers and volumes removed"),
                    _("Could not remove the containers; the project was not deleted")
                );
                if (!removed) {
                    return;
                }
            }

            if (trash_folder) {
                if (logs_cancellable != null) {
                    logs_cancellable.cancel ();
                }
                try {
                    yield File.new_for_path (project.path).trash_async (Priority.DEFAULT, cancellable);
                } catch (IOError.CANCELLED e) {
                    return;
                } catch (Error e) {
                    toast (_("Could not move the folder to the Trash: %s").printf (e.message));
                    return;
                }
            }

            // The files are gone (or intentionally kept): nothing left to save.
            set_dirty (false);
            deleted ();
        }

        private void open_folder () {
            var launcher = new Gtk.FileLauncher (File.new_for_path (project.path));
            launcher.launch.begin ((Gtk.Window) get_root (), null, (obj, res) => {
                try {
                    launcher.launch.end (res);
                } catch (Error e) {
                    toast (e.message);
                }
            });
        }

        private void open_browser (int port) {
            var launcher = new Gtk.UriLauncher ("http://localhost:%d".printf (port));
            launcher.launch.begin ((Gtk.Window) get_root (), null, (obj, res) => {
                try {
                    launcher.launch.end (res);
                } catch (Error e) {
                    toast (e.message);
                }
            });
        }

        /* --------------------------------------------------------------------- UI */

        private void build_ui () {
            stack = new Adw.ViewStack () { vexpand = true };
            stack.add_titled_with_icon (build_services_page (), "services", _("Services"), "view-grid-symbolic");
            stack.add_titled_with_icon (build_editor_page (), "editor", _("Configuration"), "document-edit-symbolic");
            stack.add_titled_with_icon (build_logs_page (), "logs", _("Logs"), "view-list-bullet-symbolic");
            output_stack_page = stack.add_titled_with_icon (build_output_page (), "output", _("Output"), "utilities-terminal-symbolic");
            stack.notify["visible-child-name"].connect (() => {
                if (stack.visible_child_name == "logs" && !logs_started) {
                    restart_logs ();
                }
            });

            var start_button = new Gtk.Button () {
                child = new Adw.ButtonContent () {
                    icon_name = "media-playback-start-symbolic",
                    label = _("Start"),
                },
                action_name = "project.up",
                tooltip_text = _("Create and Start All Services"),
            };
            start_button.add_css_class ("suggested-action");

            var stop_button = new Gtk.Button.from_icon_name ("media-playback-stop-symbolic") {
                action_name = "project.stop",
                tooltip_text = _("Stop All Services"),
            };
            var restart_button = new Gtk.Button.from_icon_name ("system-reboot-symbolic") {
                action_name = "project.restart",
                tooltip_text = _("Restart All Services"),
            };

            var menu = new Menu ();
            var images_section = new Menu ();
            images_section.append (_("_Pull Images"), "project.pull");
            images_section.append (_("_Build Images"), "project.build");
            menu.append_section (null, images_section);
            var down_section = new Menu ();
            down_section.append (_("_Remove Containers"), "project.down");
            down_section.append (_("Remove Containers and _Volumes…"), "project.down-volumes");
            menu.append_section (null, down_section);
            var project_section = new Menu ();
            project_section.append (_("_Open Folder"), "project.open-folder");
            project_section.append (_("Remove _from List…"), "project.remove");
            project_section.append (_("_Delete Project…"), "project.delete");
            menu.append_section (null, project_section);

            var menu_button = new Gtk.MenuButton () {
                icon_name = "view-more-symbolic",
                menu_model = menu,
                tooltip_text = _("Project Menu"),
            };

            spinner = new Adw.Spinner () { visible = false };

            var switcher = new Adw.ViewSwitcher () {
                stack = stack,
                policy = Adw.ViewSwitcherPolicy.WIDE,
            };

            var header = new Adw.HeaderBar () { title_widget = switcher };
            header.pack_start (start_button);
            header.pack_start (stop_button);
            header.pack_start (restart_button);
            header.pack_end (menu_button);
            header.pack_end (spinner);

            var switcher_bar = new Adw.ViewSwitcherBar () { stack = stack };

            var toolbar = new Adw.ToolbarView () { content = stack };
            toolbar.add_top_bar (header);
            toolbar.add_bottom_bar (switcher_bar);
            child = toolbar;

            var narrow = new Adw.Breakpoint (Adw.BreakpointCondition.parse ("max-width: 720sp"));
            narrow.add_setter (header, "title-widget", new Adw.WindowTitle (project.name, ""));
            narrow.add_setter (switcher_bar, "reveal", true);
            add_breakpoint (narrow);
        }

        private Gtk.Widget build_services_page () {
            var folder_button = new Gtk.Button.from_icon_name ("folder-open-symbolic") {
                action_name = "project.open-folder",
                tooltip_text = _("Open Folder"),
                valign = Gtk.Align.CENTER,
            };
            folder_button.add_css_class ("flat");

            var location_row = new Adw.ActionRow () {
                title = _("Location"),
                subtitle = Utils.home_relative (project.path),
                subtitle_selectable = true,
            };
            location_row.add_css_class ("property");
            location_row.add_suffix (folder_button);

            status_row = new Adw.ActionRow () { title = _("Status") };
            status_row.add_css_class ("property");

            var info_group = new Adw.PreferencesGroup () { title = project.name };
            project.bind_property ("name", info_group, "title", BindingFlags.DEFAULT);
            info_group.add (location_row);
            info_group.add (status_row);

            var refresh_button = new Gtk.Button.from_icon_name ("view-refresh-symbolic") {
                tooltip_text = _("Refresh"),
                valign = Gtk.Align.CENTER,
            };
            refresh_button.add_css_class ("flat");
            refresh_button.clicked.connect (() => reload ());

            services_group = new Adw.PreferencesGroup () {
                title = _("Services"),
                header_suffix = refresh_button,
            };

            var page = new Adw.PreferencesPage ();
            page.add (info_group);
            page.add (services_group);
            return page;
        }

        private Gtk.Widget build_editor_page () {
            file_model = new Gtk.StringList (null);
            file_dropdown = new Gtk.DropDown (file_model, null) { tooltip_text = _("File") };
            file_dropdown.notify["selected"].connect (on_file_selected);

            var validate_button = new Gtk.Button.with_label (_("Validate")) {
                action_name = "project.validate",
                tooltip_text = _("Check the Compose Configuration"),
            };
            var revert_button = new Gtk.Button.from_icon_name ("edit-undo-symbolic") {
                action_name = "project.revert-file",
                tooltip_text = _("Discard Changes"),
            };
            var save_button = new Gtk.Button.with_label (_("Save")) {
                action_name = "project.save-file",
                tooltip_text = _("Save (Ctrl+S)"),
            };
            save_button.add_css_class ("suggested-action");

            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            bar.add_css_class ("toolbar");
            bar.append (file_dropdown);
            bar.append (new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { hexpand = true });
            bar.append (validate_button);
            bar.append (revert_button);
            bar.append (save_button);

            editor_banner = new Adw.Banner ("");

            editor_buffer = new Gtk.TextBuffer (null);
            editor_buffer.changed.connect (() => {
                if (!loading_file) {
                    set_dirty (true);
                }
            });

            editor_view = new Gtk.TextView.with_buffer (editor_buffer) {
                monospace = true,
                top_margin = 12,
                bottom_margin = 12,
                left_margin = 12,
                right_margin = 12,
            };
            var keys = new Gtk.EventControllerKey ();
            keys.key_pressed.connect (on_editor_key_pressed);
            editor_view.add_controller (keys);

            var toolbar = new Adw.ToolbarView () {
                content = new Gtk.ScrolledWindow () { child = editor_view, vexpand = true },
                top_bar_style = Adw.ToolbarStyle.RAISED_BORDER,
            };
            toolbar.add_top_bar (bar);
            toolbar.add_top_bar (editor_banner);

            set_dirty (false);
            return toolbar;
        }

        private Gtk.Widget build_logs_page () {
            logs_services_model = new Gtk.StringList ({ _("All Services") });
            logs_service_dropdown = new Gtk.DropDown (logs_services_model, null) { tooltip_text = _("Service") };
            logs_service_dropdown.notify["selected"].connect (() => {
                if (!updating_logs_model) {
                    restart_logs ();
                }
            });

            timestamps_toggle = new Gtk.ToggleButton () {
                icon_name = "preferences-system-time-symbolic",
                tooltip_text = _("Show Timestamps"),
            };
            timestamps_toggle.toggled.connect (restart_logs);

            var reload_button = new Gtk.Button.from_icon_name ("view-refresh-symbolic") { tooltip_text = _("Reload Logs") };
            reload_button.clicked.connect (restart_logs);

            logs_view = new LogView ();

            var clear_button = new Gtk.Button.from_icon_name ("edit-clear-all-symbolic") { tooltip_text = _("Clear") };
            clear_button.clicked.connect (() => logs_view.clear ());

            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            bar.add_css_class ("toolbar");
            bar.append (logs_service_dropdown);
            bar.append (new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { hexpand = true });
            bar.append (timestamps_toggle);
            bar.append (reload_button);
            bar.append (clear_button);

            var toolbar = new Adw.ToolbarView () {
                content = logs_view,
                top_bar_style = Adw.ToolbarStyle.RAISED_BORDER,
            };
            toolbar.add_top_bar (bar);
            return toolbar;
        }

        private Gtk.Widget build_output_page () {
            output_view = new LogView ();

            var hint = new Gtk.Label (_("Output of the commands run on this project")) {
                xalign = 0,
                hexpand = true,
                margin_start = 6,
                ellipsize = Pango.EllipsizeMode.END,
            };
            hint.add_css_class ("dim-label");

            var clear_button = new Gtk.Button.from_icon_name ("edit-clear-all-symbolic") { tooltip_text = _("Clear") };
            clear_button.clicked.connect (() => output_view.clear ());

            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            bar.add_css_class ("toolbar");
            bar.append (hint);
            bar.append (clear_button);

            var toolbar = new Adw.ToolbarView () {
                content = output_view,
                top_bar_style = Adw.ToolbarStyle.RAISED_BORDER,
            };
            toolbar.add_top_bar (bar);
            return toolbar;
        }

        /* --------------------------------------------------------------- services */

        private void update_status_row () {
            status_row.subtitle = project.status_label;
        }

        public async void refresh_services (bool reload_config = false) {
            if (refreshing_services) {
                config_reload_pending = config_reload_pending || reload_config;
                return;
            }
            refreshing_services = true;

            try {
                if (reload_config || !config_loaded) {
                    var config = yield Docker.run (project.path, compose_args ({ "config", "--services" }), cancellable);
                    config_loaded = true;
                    if (config.success) {
                        service_names = Utils.split_lines (config.stdout_text);
                        services_group.description = null;
                    } else {
                        service_names = {};
                        services_group.description = config.stderr_text.strip ();
                    }
                    update_logs_services ();
                }

                var infos = new HashTable<string, ServiceInfo> (str_hash, str_equal);
                string[] order = {};
                foreach (unowned string name in service_names) {
                    infos[name] = new ServiceInfo (name);
                    order += name;
                }

                var ps = yield Docker.run (project.path, compose_args ({ "ps", "--all", "--format", PS_FORMAT }), cancellable);
                if (ps.success) {
                    foreach (unowned string line in ps.stdout_text.split ("\n")) {
                        var fields = line.split ("\t");
                        if (fields.length < 5) {
                            continue;
                        }
                        var info = infos[fields[0]];
                        if (info == null) {
                            // Orphan container of a service no longer in the file.
                            info = new ServiceInfo (fields[0]);
                            infos[fields[0]] = info;
                            order += fields[0];
                        }
                        info.add_container (fields[2], fields[3], fields[4]);
                    }
                }

                update_service_rows (infos, order);
            } catch (IOError.CANCELLED e) {
                return;
            } catch (Error e) {
                services_group.description = e.message;
            }

            refreshing_services = false;
            if (config_reload_pending) {
                config_reload_pending = false;
                yield refresh_services (true);
            }
        }

        private void update_service_rows (HashTable<string, ServiceInfo> infos, string[] order) {
            foreach (var name in service_rows.get_keys ()) {
                if (!infos.contains (name)) {
                    services_group.remove (service_rows[name]);
                    service_rows.remove (name);
                }
            }

            foreach (unowned string name in order) {
                var row = service_rows[name];
                if (row == null) {
                    row = new ServiceRow (name);
                    row.action_requested.connect (on_service_action);
                    row.set_actions_sensitive (!busy);
                    services_group.add (row);
                    service_rows[name] = row;
                }
                row.update (infos[name]);
            }

            if (order.length == 0 && services_group.description == null) {
                services_group.description = _("No services defined");
            }
        }

        private void on_service_action (ServiceRow row, string action) {
            var service = row.service;
            switch (action) {
                case "start":
                    run_compose.begin ({ "up", "--detach", service },
                                       _("Service “%s” started").printf (service),
                                       _("Could not start “%s”").printf (service));
                    break;
                case "stop":
                    run_compose.begin ({ "stop", service },
                                       _("Service “%s” stopped").printf (service),
                                       _("Could not stop “%s”").printf (service));
                    break;
                case "restart":
                    run_compose.begin ({ "restart", service },
                                       _("Service “%s” restarted").printf (service),
                                       _("Could not restart “%s”").printf (service));
                    break;
                case "logs":
                    show_logs_for (service);
                    break;
                case "open":
                    open_browser (row.host_port);
                    break;
            }
        }

        /* ------------------------------------------------------------------- logs */

        private void update_logs_services () {
            string? selected = null;
            if (logs_service_dropdown.selected > 0 && logs_service_dropdown.selected != Gtk.INVALID_LIST_POSITION) {
                selected = logs_services_model.get_string (logs_service_dropdown.selected);
            }

            updating_logs_model = true;
            logs_services_model.splice (1, logs_services_model.get_n_items () - 1, service_names);
            uint position = 0;
            for (int i = 0; i < service_names.length; i++) {
                if (service_names[i] == selected) {
                    position = i + 1;
                }
            }
            logs_service_dropdown.selected = position;
            updating_logs_model = false;
        }

        private void show_logs_for (string service) {
            uint position = 0;
            for (uint i = 1; i < logs_services_model.get_n_items (); i++) {
                if (logs_services_model.get_string (i) == service) {
                    position = i;
                }
            }
            updating_logs_model = true;
            logs_service_dropdown.selected = position;
            updating_logs_model = false;

            logs_started = true;
            stack.visible_child_name = "logs";
            restart_logs ();
        }

        private void restart_logs () {
            if (logs_cancellable != null) {
                logs_cancellable.cancel ();
            }
            logs_started = true;
            logs_view.clear ();

            var stream_cancellable = new Cancellable ();
            logs_cancellable = stream_cancellable;

            string[] args = { "logs", "--follow", "--no-color", "--tail", "500" };
            if (timestamps_toggle.active) {
                args += "--timestamps";
            }
            var selected = logs_service_dropdown.selected;
            if (selected > 0 && selected != Gtk.INVALID_LIST_POSITION) {
                args += logs_services_model.get_string (selected);
            }

            Docker.stream.begin (project.path, compose_args (args), (line) => {
                if (!stream_cancellable.is_cancelled ()) {
                    logs_view.append (line + "\n");
                }
            }, stream_cancellable, (obj, res) => {
                try {
                    Docker.stream.end (res);
                    if (!stream_cancellable.is_cancelled ()) {
                        logs_view.append ("— %s —\n".printf (_("Log stream ended")));
                    }
                } catch (IOError.CANCELLED e) {
                } catch (Error e) {
                    logs_view.append (e.message + "\n");
                }
            });
        }

        /* ----------------------------------------------------------------- editor */

        private void reload_editor_files () {
            editor_files = project.editable_files ();
            switching_file = true;
            file_model.splice (0, file_model.get_n_items (), editor_files);
            file_dropdown.selected = 0;
            switching_file = false;
            load_file_at (0);
        }

        private void set_dirty (bool value) {
            dirty = value;
            set_action_enabled ("save-file", value);
            set_action_enabled ("revert-file", value);
        }

        private void load_file_at (uint index) {
            current_file_index = index;
            editing_path = Path.build_filename (project.path, editor_files[index]);

            string contents = "";
            if (FileUtils.test (editing_path, FileTest.EXISTS)) {
                try {
                    FileUtils.get_contents (editing_path, out contents);
                } catch (Error e) {
                    toast (e.message);
                }
            }

            loading_file = true;
            editor_buffer.begin_irreversible_action ();
            editor_buffer.text = contents;
            editor_buffer.end_irreversible_action ();
            loading_file = false;

            Gtk.TextIter start;
            editor_buffer.get_start_iter (out start);
            editor_buffer.place_cursor (start);

            editor_banner.revealed = false;
            set_dirty (false);
        }

        private void on_file_selected () {
            if (switching_file || file_dropdown.selected == current_file_index) {
                return;
            }
            if (!dirty) {
                load_file_at (file_dropdown.selected);
                return;
            }
            var target = file_dropdown.selected;
            ask_save_before_switch.begin (target);
        }

        private async void ask_save_before_switch (uint target) {
            var dialog = new Adw.AlertDialog (
                _("Save Changes?"),
                _("“%s” has unsaved changes.").printf (editing_file_name)
            );
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("discard", _("_Discard"));
            dialog.add_response ("save", _("_Save"));
            dialog.set_response_appearance ("discard", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_response_appearance ("save", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "save";
            dialog.close_response = "cancel";

            var response = yield dialog.choose (this, null);
            if (response == "cancel") {
                switching_file = true;
                file_dropdown.selected = current_file_index;
                switching_file = false;
                return;
            }
            if (response == "save") {
                save_file ();
            }
            load_file_at (target);
        }

        public void save_file () {
            if (editing_path == null || !dirty) {
                return;
            }
            Gtk.TextIter start, end;
            editor_buffer.get_bounds (out start, out end);
            var text = editor_buffer.get_text (start, end, true);

            try {
                // replace_contents keeps the permissions of an existing file (e.g. a 0600 .env)
                File.new_for_path (editing_path).replace_contents (text.data, null, false, FileCreateFlags.NONE, null);
            } catch (Error e) {
                toast (_("Could not save: %s").printf (e.message));
                return;
            }
            set_dirty (false);
            toast (_("Saved “%s”").printf (editing_file_name));

            if (editing_file_name != "Dockerfile") {
                validate.begin (true);
            }
        }

        private async void validate (bool after_save) {
            try {
                var result = yield Docker.run (project.path, compose_args ({ "config", "--quiet" }), cancellable);
                if (result.success) {
                    editor_banner.revealed = false;
                    if (!after_save) {
                        toast (_("The configuration is valid"));
                    }
                    reload ();
                } else {
                    editor_banner.title = Markup.escape_text (result.stderr_text.strip ());
                    editor_banner.revealed = true;
                }
            } catch (IOError.CANCELLED e) {
            } catch (Error e) {
                toast (e.message);
            }
        }

        /* YAML forbids tabs: indent with spaces and keep indentation on new lines. */
        private bool on_editor_key_pressed (uint keyval, uint keycode, Gdk.ModifierType state) {
            if ((state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK)) != 0) {
                return false;
            }
            if (keyval == Gdk.Key.Tab) {
                editor_buffer.insert_at_cursor ("  ", -1);
                return true;
            }
            if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) {
                Gtk.TextIter cursor, line_start;
                editor_buffer.get_iter_at_mark (out cursor, editor_buffer.get_insert ());
                line_start = cursor;
                line_start.set_line_offset (0);
                var line = editor_buffer.get_text (line_start, cursor, false);

                var indent = new StringBuilder ();
                for (int i = 0; i < line.length && line[i] == ' '; i++) {
                    indent.append_c (' ');
                }
                if (line.strip ().has_suffix (":")) {
                    indent.append ("  ");
                }
                editor_buffer.insert_at_cursor ("\n" + indent.str, -1);
                editor_view.scroll_mark_onscreen (editor_buffer.get_insert ());
                return true;
            }
            return false;
        }
    }
}
