namespace DockStation {
    public enum EditorFileKind {
        COMPOSE,
        DOCKERFILE,
    }

    /* A file listed in the Configuration tab, relative to the project folder. */
    public class EditorFile : Object {
        public string path { get; construct; }
        public EditorFileKind kind { get; construct; }

        public EditorFile (string path, EditorFileKind kind) {
            Object (path: path, kind: kind);
        }

        public string section_title {
            owned get { return kind == EditorFileKind.COMPOSE ? _("Compose") : _("Dockerfiles"); }
        }
    }

    /* Keeps the previous line's indentation, adding a level after lines that open a block ("key:"). */
    public class YamlIndenter : Object, GtkSource.Indenter {
        public bool is_trigger (GtkSource.View view, Gtk.TextIter location, Gdk.ModifierType state, uint keyval) {
            if ((state & (Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.CONTROL_MASK)) != 0) {
                return false;
            }
            return keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter;
        }

        /* Called with `iter` at the start of the new line. */
        public void indent (GtkSource.View view, ref Gtk.TextIter iter) {
            var previous = iter;
            if (!previous.backward_line ()) {
                return;
            }
            var previous_end = previous;
            if (!previous_end.ends_line ()) {
                previous_end.forward_to_line_end ();
            }
            var line = previous.get_slice (previous_end);

            var indent = new StringBuilder ();
            for (int i = 0; i < line.length && (line[i] == ' ' || line[i] == '\t'); i++) {
                indent.append_c (line[i]);
            }
            if (opens_block (line)) {
                var width = view.indent_width > 0 ? view.indent_width : (int) view.tab_width;
                indent.append (string.nfill (width, ' '));
            }

            // Replace the whitespace that followed the cursor, if any.
            var buffer = view.buffer;
            var whitespace_end = iter;
            while (!whitespace_end.ends_line () && (whitespace_end.get_char () == ' ' || whitespace_end.get_char () == '\t')) {
                whitespace_end.forward_char ();
            }
            buffer.delete (ref iter, ref whitespace_end);
            buffer.insert (ref iter, indent.str, -1);
        }

        /* "key:" or a block scalar ("key: |", "key: >-"), ignoring trailing comments. */
        private static bool opens_block (string line) {
            var text = line.strip ();
            if (text.has_prefix ("#")) {
                return false;
            }
            var comment = text.index_of (" #");
            if (comment >= 0) {
                text = text.substring (0, comment).strip ();
            }
            return text.has_suffix (":") || Regex.match_simple ("""(^|:\s)[|>][-+]?$""", text);
        }
    }

    public class ProjectView : Adw.BreakpointBin {
        public Project project { get; construct; }

        public signal void toast (string message);
        public signal void remove_requested ();
        /* Emitted after the project was deleted from disk; the view must be discarded. */
        public signal void deleted ();
        public signal void containers_changed ();

        private const string[] COMPOSE_ACTIONS = { "up", "stop", "restart", "down", "pull", "build", "down-volumes", "recreate", "delete" };
        private const string PS_FORMAT = "{{.Service}}\t{{.Name}}\t{{.State}}\t{{.Status}}\t{{.Ports}}\t{{.ID}}";

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
        // Databases that can be reset, keyed by container ID; inspected again when the IDs change.
        private HashTable<string, DatabaseInit> databases = new HashTable<string, DatabaseInit> (str_hash, str_equal);
        // Traefik addresses per container ID, read from the containers' labels.
        private HashTable<string, GenericArray<TraefikRoute>> traefik_routes =
            new HashTable<string, GenericArray<TraefikRoute>> (str_hash, str_equal);
        private string inspected_containers = "";
        private bool config_reload_pending = false;

        // Editor page
        private GLib.ListStore file_store;
        private Gtk.SortListModel file_list;
        private Cancellable? dockerfile_search = null;
        private Gtk.DropDown file_dropdown;
        private GtkSource.Buffer editor_buffer;
        private GtkSource.View editor_view;
        private Adw.Banner editor_banner;
        private uint current_file_index = 0;
        private string? editing_path = null;
        // Identifies the version on disk that was loaded, to detect changes made by other programs.
        private string? editing_etag = null;
        private bool loading_file = false;
        private bool switching_file = false;
        private bool dirty = false;
        private bool saving = false;
        // Bumped on every edit, so a save only clears `dirty` if nothing was typed meanwhile.
        private uint edit_serial = 0;

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
            owned get { return editing_path != null ? File.new_for_path (project.path).get_relative_path (File.new_for_path (editing_path)) ?? Path.get_basename (editing_path) : ""; }
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
            if (dockerfile_search != null) {
                dockerfile_search.cancel ();
            }
            if (logs_cancellable != null) {
                logs_cancellable.cancel ();
            }
            if (status_handler != 0) {
                project.disconnect (status_handler);
                status_handler = 0;
            }
            Adw.StyleManager.get_default ().notify["dark"].disconnect (update_editor_scheme);
        }

        public void reload () {
            refresh_services.begin (true);
            rescan_dockerfiles.begin ();
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
            add_simple_action ("recreate", () => confirm_recreate.begin ());
            add_simple_action ("open-folder", open_folder);
            add_simple_action ("remove", () => remove_requested ());
            add_simple_action ("delete", () => delete_project.begin ());
            add_simple_action ("save-file", () => save_file.begin ());
            add_simple_action ("revert-file", () => load_file_at (current_file_index));
            add_simple_action ("validate", () => validate.begin (false));
            add_simple_action ("add-service", () => show_add_service.begin ());

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
            return Docker.compose_args (args);
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

        /* Returns true if the command ran and exited successfully. An empty `success_message` shows no toast. */
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
                    if (success_message != "") {
                        toast (success_message);
                    }
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

        /*
         * Creates every container again from its image. Fixes what Start and Restart cannot,
         * because Docker only sets it when a container is created: its DNS configuration,
         * network attachments and hostname.
         */
        private async void confirm_recreate () {
            var dialog = new Adw.AlertDialog (
                _("Recreate Containers?"),
                _("The containers are created again from their images and started. Data in volumes and project folders is kept; changes made inside the containers are lost.")
            );
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("recreate", _("_Recreate"));
            dialog.set_response_appearance ("recreate", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";

            if ((yield dialog.choose (this, null)) == "recreate") {
                // --remove-orphans also removes containers of services that no longer exist.
                yield run_compose ({ "up", "--detach", "--force-recreate", "--remove-orphans" },
                                   _("Containers recreated"), _("Could not recreate the containers"));
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

        private async void show_add_service () {
            if (project.compose_files ().length == 0) {
                toast (_("No compose file found in %s").printf (Utils.home_relative (project.path)));
                return;
            }
            // Adding a service changes the compose file and .env on disk.
            if (dirty && !(yield settle_unsaved_changes ())) {
                return;
            }
            var dialog = new AddServiceDialog (project, service_names);
            dialog.added.connect ((service, start) => on_service_added.begin (service, start));
            dialog.present (this);
        }

        private async void on_service_added (string service, bool start) {
            toast (_("Added “%s”").printf (service));
            reload_editor_files ();
            if (start) {
                yield run_compose ({ "up", "--detach", service },
                                   _("Service “%s” started").printf (service),
                                   _("Could not start “%s”").printf (service));
            }
            reload ();
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

        private void open_browser (string url) {
            var launcher = new Gtk.UriLauncher (url);
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
            down_section.append (_("Re_create Containers…"), "project.recreate");
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

            var add_button = new Gtk.Button.from_icon_name ("list-add-symbolic") {
                action_name = "project.add-service",
                tooltip_text = _("Add Service…"),
                valign = Gtk.Align.CENTER,
            };
            add_button.add_css_class ("flat");

            var header_buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            header_buttons.append (add_button);
            header_buttons.append (refresh_button);

            services_group = new Adw.PreferencesGroup () {
                title = _("Services"),
                header_suffix = header_buttons,
            };

            var page = new Adw.PreferencesPage ();
            page.add (info_group);
            page.add (services_group);
            return page;
        }

        private Gtk.Widget build_editor_page () {
            // The store is kept grouped by kind; the section sorter only marks where sections start.
            file_store = new GLib.ListStore (typeof (EditorFile));
            file_list = new Gtk.SortListModel (file_store, null) {
                section_sorter = new Gtk.CustomSorter ((a, b) => {
                    return (int) ((EditorFile) a).kind - (int) ((EditorFile) b).kind;
                }),
            };

            var item_factory = new Gtk.SignalListItemFactory ();
            item_factory.setup.connect ((obj) => {
                ((Gtk.ListItem) obj).child = new Gtk.Label (null) {
                    xalign = 0,
                    ellipsize = Pango.EllipsizeMode.MIDDLE,
                    max_width_chars = 36,
                };
            });
            item_factory.bind.connect ((obj) => {
                var item = (Gtk.ListItem) obj;
                var label = (Gtk.Label) item.child;
                label.label = ((EditorFile) item.item).path;
                label.tooltip_text = label.label;
            });

            var header_factory = new Gtk.SignalListItemFactory ();
            header_factory.setup.connect ((obj) => {
                var label = new Gtk.Label (null) { xalign = 0 };
                label.add_css_class ("heading");
                ((Gtk.ListHeader) obj).child = label;
            });
            header_factory.bind.connect ((obj) => {
                var header = (Gtk.ListHeader) obj;
                ((Gtk.Label) header.child).label = ((EditorFile) header.item).section_title;
            });

            file_dropdown = new Gtk.DropDown (file_list, null) {
                factory = item_factory,
                header_factory = header_factory,
                tooltip_text = _("File"),
            };
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

            editor_buffer = new GtkSource.Buffer (null);
            editor_buffer.changed.connect (() => {
                if (!loading_file) {
                    edit_serial++;
                    set_dirty (true);
                }
            });

            update_editor_scheme ();
            Adw.StyleManager.get_default ().notify["dark"].connect (update_editor_scheme);

            editor_view = new GtkSource.View.with_buffer (editor_buffer) {
                monospace = true,
                top_margin = 12,
                bottom_margin = 12,
                left_margin = 6,
                right_margin = 12,
                show_line_numbers = true,
                highlight_current_line = true,
                auto_indent = true,
                indent_on_tab = true,
                smart_backspace = true,
                // YAML forbids tabs.
                insert_spaces_instead_of_tabs = true,
            };
            editor_buffer.highlight_matching_brackets = true;
            // Make tabs visible: they break YAML and are easy to miss.
            editor_view.space_drawer.set_types_for_locations (GtkSource.SpaceLocationFlags.ALL,
                                                              GtkSource.SpaceTypeFlags.TAB);
            editor_view.space_drawer.enable_matrix = true;

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
                        info.add_container (fields.length > 5 ? fields[5] : "", fields[2], fields[3], fields[4]);
                    }
                }

                yield inspect_containers (infos, order);
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

        /*
         * Reads what DockStation needs from the containers themselves: databases
         * with init scripts (see DatabaseInit) and Traefik routes (see Traefik).
         */
        private async void inspect_containers (HashTable<string, ServiceInfo> infos, string[] order) {
            string[] ids = {};
            foreach (unowned string name in order) {
                var info = infos[name];
                if (info.containers == 1 && info.container_id != "") {
                    ids += info.container_id;
                }
            }
            var key = string.joinv (",", ids);
            if (key == inspected_containers) {
                return;
            }
            try {
                databases = yield DatabaseInit.inspect (ids, cancellable);
                traefik_routes = yield Traefik.inspect (ids, cancellable);
                inspected_containers = key;
            } catch (Error e) {
                // Not critical: the reset and link buttons just stay hidden.
            }
        }

        private void update_service_rows (HashTable<string, ServiceInfo> infos, string[] order) {
            foreach (var name in service_rows.get_keys ()) {
                if (!infos.contains (name)) {
                    services_group.remove (service_rows[name]);
                    service_rows.remove (name);
                }
            }

            var removable = ServiceRemover.added_services (project);
            foreach (unowned string name in order) {
                var row = service_rows[name];
                if (row == null) {
                    row = new ServiceRow (name);
                    row.action_requested.connect (on_service_action);
                    row.open_url.connect (open_browser);
                    row.set_actions_sensitive (!busy);
                    services_group.add (row);
                    service_rows[name] = row;
                }
                var info = infos[name];
                row.show_traefik_routes (info.container_id != "" ? traefik_routes[info.container_id] : null);
                row.update (info);
                row.show_database_reset (info.containers == 1 ? databases[info.container_id] : null);
                row.show_remove (name in removable);
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
                case "reset-database":
                    if (row.database != null) {
                        reset_database.begin (service, row.database);
                    }
                    break;
                case "remove-service":
                    remove_service.begin (service);
                    break;
            }
        }

        /* --------------------------------------------------------- service removal */

        private async void remove_service (string service) {
            if (busy) {
                return;
            }
            // Removing a service changes the compose file and .env on disk.
            if (dirty && !(yield settle_unsaved_changes ())) {
                return;
            }

            ServiceRemoval removal;
            try {
                removal = yield ServiceRemover.prepare (project, service);
            } catch (Error e) {
                var alert = new Adw.AlertDialog (_("Could Not Remove the Service"), e.message);
                alert.add_response ("close", _("_Close"));
                alert.present (this);
                return;
            }

            var data_row = new Adw.SwitchRow () {
                title = _("Delete Its Data"),
                subtitle = ngettext ("Permanently deletes the volume %s", "Permanently deletes the volumes %s",
                                     removal.volumes.length).printf (string.joinv (", ", removal.volumes)),
            };
            var options = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
            options.add_css_class ("boxed-list");
            options.append (data_row);

            var dialog = new Adw.AlertDialog (
                _("Remove Service “%s”?").printf (service),
                _("Its container is removed, and %s and its settings in .env are deleted. Files in its folders are kept.")
                    .printf (removal.service_file.get_basename ())
            );
            if (removal.volumes.length > 0) {
                dialog.extra_child = options;
            }
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("remove", _("_Remove"));
            dialog.set_response_appearance ("remove", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            if ((yield dialog.choose (this, null)) != "remove") {
                return;
            }

            // The container first: once the service is gone from the files, Compose no longer knows it.
            if (!(yield run_compose ({ "rm", "--stop", "--force", "--volumes", service }, "",
                                     _("Could not remove the “%s” container").printf (service)))) {
                return;
            }
            if (data_row.active) {
                foreach (unowned string volume in removal.volumes) {
                    try {
                        if (!(yield run_step ({ "volume", "rm", volume }))) {
                            toast (_("Could not delete the volume %s").printf (volume));
                        }
                    } catch (Error e) {
                        toast (e.message);
                    }
                }
            }

            try {
                ServiceRemover.apply (removal);
            } catch (Error e) {
                toast (_("Could not remove “%s”: %s").printf (service, e.message));
                return;
            }
            toast (_("Removed “%s”").printf (service));
            reload_editor_files ();
            reload ();
        }

        /* --------------------------------------------------------- database reset */

        /* Refuses to empty folders that obviously hold more than the database. */
        private string? unsafe_data_folder (string source) {
            var folder = File.new_for_path (source);
            var home = File.new_for_path (Environment.get_home_dir ());
            var project_folder = File.new_for_path (project.path);
            if (folder.get_parent () == null || folder.equal (home) || folder.equal (project_folder)
                || home.has_prefix (folder) || project_folder.has_prefix (folder)) {
                return _("The data folder “%s” is not a dedicated database folder, so it will not be emptied.")
                    .printf (Utils.home_relative (source));
            }
            return null;
        }

        private async bool run_step (owned string[] docker_args) throws Error {
            output_view.append ("$ docker %s\n".printf (string.joinv (" ", docker_args)));
            int status = yield Docker.stream (project.path, docker_args, (line) => {
                output_view.append (line + "\n");
            }, cancellable);
            if (status != 0) {
                output_view.append ("✘ " + _("Exited with status %d").printf (status) + "\n\n");
            }
            return status == 0;
        }

        private async void reset_database (string service, DatabaseInit database) {
            if (busy) {
                return;
            }
            if (database.data_type == "bind") {
                var problem = unsafe_data_folder (database.data_source);
                if (problem != null) {
                    toast (problem);
                    return;
                }
            }

            string storage;
            if (database.data_type == "bind") {
                storage = _("the folder “%s”").printf (Utils.home_relative (database.data_source));
            } else if (database.data_is_anonymous_volume) {
                storage = _("an unnamed volume");
            } else {
                storage = _("the volume “%s”").printf (database.data_volume);
            }

            string scripts = "";
            const int MAX_LISTED = 8;
            for (int i = 0; i < database.init_files.length && i < MAX_LISTED; i++) {
                scripts += "\n• " + Path.get_basename (database.init_files[i]);
            }
            if (database.init_files.length > MAX_LISTED) {
                scripts += "\n• " + _("and %d more").printf (database.init_files.length - MAX_LISTED);
            }
            foreach (unowned string volume in database.init_volumes) {
                scripts += "\n• " + _("the scripts in the volume “%s”").printf (volume);
            }

            var dialog = new Adw.AlertDialog (
                _("Reset Database “%s”?").printf (service),
                _("All data in this %s database, stored in %s, is deleted permanently. This cannot be undone.").printf (database.engine, storage)
                + "\n\n" + _("The database is then created again, running its init scripts:") + scripts
            );
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("reset", _("_Reset Database"));
            dialog.set_response_appearance ("reset", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            if ((yield dialog.choose (this, null)) != "reset") {
                return;
            }

            set_busy (true);
            stack.visible_child_name = "output";
            output_view.append ("# " + _("Resetting the “%s” database").printf (service) + "\n");
            bool success = false;
            try {
                // 1. Stop and remove the container; --volumes also drops an unnamed data volume.
                if ((yield run_step (compose_args ({ "stop", service })))
                    && (yield run_step (compose_args ({ "rm", "--force", "--volumes", service })))) {
                    // 2. Empty the data, so the entrypoint initialises the database again.
                    bool emptied = true;
                    if (database.data_type == "volume" && !database.data_is_anonymous_volume) {
                        emptied = yield run_step ({ "volume", "rm", database.data_volume });
                    } else if (database.data_type == "bind") {
                        // Run as root inside the database image: the files belong to its user.
                        emptied = yield run_step ({
                            "run", "--rm", "--entrypoint", "sh", "--volume", database.data_source + ":/reset",
                            database.image_id, "-c", "find /reset -mindepth 1 -delete"
                        });
                    }
                    // 3. Start it again, even after a failure, so the service is not left down.
                    bool started = yield run_step (compose_args ({ "up", "--detach", service }));
                    success = emptied && started;
                }
            } catch (IOError.CANCELLED e) {
                return;
            } catch (Error e) {
                output_view.append (e.message + "\n\n");
            }
            set_busy (false);
            output_view.append ((success ? "✔ " + _("Done") : "✘ " + _("The database was not reset")) + "\n\n");

            containers_changed ();
            yield refresh_services (false);
            if (success) {
                toast (_("Database “%s” reset; its init scripts are running").printf (service));
                // The init scripts' progress shows up in the logs.
                show_logs_for (service);
            } else {
                toast (_("Could not reset the “%s” database").printf (service));
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

        private EditorFile file_at (uint position) {
            return (EditorFile) file_list.get_item (position);
        }

        private uint position_of (string? path) {
            for (uint i = 0; path != null && i < file_list.get_n_items (); i++) {
                if (file_at (i).path == path) {
                    return i;
                }
            }
            return Gtk.INVALID_LIST_POSITION;
        }

        private void reload_editor_files () {
            Object[] files = {};
            foreach (unowned string path in project.editable_files ()) {
                files += new EditorFile (path, EditorFileKind.COMPOSE);
            }
            switching_file = true;
            file_store.splice (0, file_store.get_n_items (), files);
            file_dropdown.selected = 0;
            switching_file = false;
            load_file_at (0);
            rescan_dockerfiles.begin ();
        }

        /* Searches the project for Dockerfiles and lists them in their own section. */
        private async void rescan_dockerfiles () {
            if (dockerfile_search != null) {
                dockerfile_search.cancel ();
            }
            var search = new Cancellable ();
            dockerfile_search = search;

            var dockerfiles = yield project.find_dockerfiles (search);
            if (search.is_cancelled ()) {
                return;
            }

            uint first = 0;
            while (first < file_store.get_n_items ()
                   && ((EditorFile) file_store.get_item (first)).kind == EditorFileKind.COMPOSE) {
                first++;
            }

            // Keep a Dockerfile that is open in the editor, even if it was moved or deleted.
            var editing = editing_file_name;
            string[] paths = dockerfiles;
            uint editing_position = position_of (editing);
            if (editing_position != Gtk.INVALID_LIST_POSITION
                && file_at (editing_position).kind == EditorFileKind.DOCKERFILE
                && !(editing in paths)) {
                paths += editing;
            }

            string[] current = {};
            for (uint i = first; i < file_store.get_n_items (); i++) {
                current += ((EditorFile) file_store.get_item (i)).path;
            }
            if (string.joinv ("\n", current) == string.joinv ("\n", paths)) {
                return;
            }

            Object[] items = {};
            foreach (unowned string path in paths) {
                items += new EditorFile (path, EditorFileKind.DOCKERFILE);
            }
            switching_file = true;
            file_store.splice (first, file_store.get_n_items () - first, items);
            var position = position_of (editing);
            if (position != Gtk.INVALID_LIST_POSITION) {
                current_file_index = position;
                file_dropdown.selected = position;
            }
            switching_file = false;
        }

        private void set_dirty (bool value) {
            dirty = value;
            set_action_enabled ("save-file", value);
            set_action_enabled ("revert-file", value);
        }

        private void load_file_at (uint index) {
            current_file_index = index;
            var file = file_at (index);
            editing_path = Path.build_filename (project.path, file.path);
            configure_editor_for (file);

            uint8[] contents = {};
            editing_etag = null;
            try {
                File.new_for_path (editing_path).load_contents (null, out contents, out editing_etag);
            } catch (IOError.NOT_FOUND e) {
                // Not created yet (e.g. .env): saving creates it.
            } catch (Error e) {
                toast (e.message);
            }

            loading_file = true;
            editor_buffer.begin_irreversible_action ();
            editor_buffer.text = contents.length > 0 ? (string) contents : "";
            editor_buffer.end_irreversible_action ();
            loading_file = false;

            Gtk.TextIter start;
            editor_buffer.get_start_iter (out start);
            editor_buffer.place_cursor (start);

            editor_banner.revealed = false;
            set_dirty (false);
        }

        /* Highlighting and indentation rules depend on the kind of file. */
        private void configure_editor_for (EditorFile file) {
            string language_id;
            if (file.kind == EditorFileKind.DOCKERFILE) {
                language_id = "docker";
            } else if (Path.get_basename (file.path) == ".env") {
                language_id = "sh";
            } else {
                language_id = "yaml";
            }
            editor_buffer.language = GtkSource.LanguageManager.get_default ().get_language (language_id);

            bool yaml = language_id == "yaml";
            editor_view.tab_width = yaml ? 2 : 4;
            editor_view.indenter = yaml ? new YamlIndenter () : null;
        }

        private void update_editor_scheme () {
            var scheme_id = Adw.StyleManager.get_default ().dark ? "Adwaita-dark" : "Adwaita";
            editor_buffer.style_scheme = GtkSource.StyleSchemeManager.get_default ().get_scheme (scheme_id);
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
            if (!(yield settle_unsaved_changes ())) {
                switching_file = true;
                file_dropdown.selected = current_file_index;
                switching_file = false;
                return;
            }
            load_file_at (target);
        }

        /*
         * Asks whether to save or discard the editor's changes. Returns false if the
         * user cancelled or the file could not be saved; the changes are then kept.
         */
        private async bool settle_unsaved_changes () {
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
            if (response == "save") {
                return yield save_file ();
            }
            if (response == "discard") {
                load_file_at (current_file_index);
                return true;
            }
            return false;
        }

        /* Returns true if the editor holds no unsaved changes afterwards. */
        public async bool save_file () {
            if (editing_path == null || !dirty) {
                return !dirty;
            }
            if (saving) {
                return false;
            }
            saving = true;
            var saved = yield write_editor_file ();
            saving = false;
            return saved;
        }

        private async bool write_editor_file () {
            var path = editing_path;
            var name = editing_file_name;
            var kind = file_at (current_file_index).kind;
            var serial = edit_serial;
            Gtk.TextIter start, end;
            editor_buffer.get_bounds (out start, out end);
            var contents = new Bytes (editor_buffer.get_text (start, end, true).data);
            var etag = editing_etag;

            while (true) {
                try {
                    string? new_etag;
                    // replace_contents keeps the permissions of an existing file (e.g. a 0600 .env).
                    // With an etag it fails instead of overwriting changes made by another program.
                    yield File.new_for_path (path).replace_contents_bytes_async (
                        contents, etag, false, FileCreateFlags.NONE, null, out new_etag);
                    if (editing_path == path) {
                        editing_etag = new_etag;
                    }
                    break;
                } catch (IOError.WRONG_ETAG e) {
                    var response = yield ask_overwrite_changed_file (name);
                    if (response == "overwrite") {
                        etag = null;
                        continue;
                    }
                    if (response == "reload" && editing_path == path) {
                        load_file_at (current_file_index);
                    }
                    return !dirty;
                } catch (Error e) {
                    toast (_("Could not save: %s").printf (e.message));
                    return false;
                }
            }

            // Keep the file marked as modified if it was edited while saving.
            if (editing_path == path && edit_serial == serial) {
                set_dirty (false);
            }
            toast (_("Saved “%s”").printf (name));

            // Only compose files and .env affect `docker compose config`.
            if (kind == EditorFileKind.COMPOSE) {
                validate.begin (true);
            }
            return !dirty;
        }

        private async string ask_overwrite_changed_file (string name) {
            var dialog = new Adw.AlertDialog (
                _("File Changed on Disk"),
                _("“%s” was modified by another program after it was opened. Overwrite it with your version, or reload it and discard your changes?").printf (name)
            );
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("reload", _("_Reload"));
            dialog.add_response ("overwrite", _("_Overwrite"));
            dialog.set_response_appearance ("reload", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_response_appearance ("overwrite", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            return yield dialog.choose (this, null);
        }

        private async void validate (bool after_save) {
            string? edited = null;
            string? copy = null;
            try {
                string[] args = {};
                // Check the text in the editor, not the file on disk: Compose gets a copy of it instead.
                if (dirty && file_at (current_file_index).kind == EditorFileKind.COMPOSE) {
                    edited = editing_path;
                    args = compose_args_with_copy (edited, out copy);
                }
                args += "config";
                args += "--quiet";

                var result = yield Docker.run (project.path, compose_args (args), cancellable);
                if (result.success) {
                    editor_banner.revealed = false;
                    if (!after_save) {
                        toast (_("The configuration is valid"));
                    }
                    // The services list reflects the files on disk.
                    if (copy == null) {
                        reload ();
                    }
                } else {
                    var message = result.stderr_text.strip ();
                    if (copy != null) {
                        message = message.replace (copy, edited)
                            .replace (Path.get_basename (copy), Path.get_basename (edited));
                    }
                    editor_banner.title = Markup.escape_text (message);
                    editor_banner.revealed = true;
                }
            } catch (IOError.CANCELLED e) {
            } catch (Error e) {
                toast (e.message);
            } finally {
                if (copy != null) {
                    FileUtils.unlink (copy);
                }
            }
        }

        /*
         * Compose options that load a copy of the editor text in place of `edited`. `copy` is
         * left null (and no options returned) when Compose does not load that file at all.
         */
        private string[] compose_args_with_copy (string edited, out string? copy) throws Error {
            copy = null;
            var edited_file = File.new_for_path (edited);
            if (Path.get_basename (edited) == ".env") {
                copy = write_editor_copy (edited);
                return { "--env-file", copy };
            }

            var files = project.compose_files ();
            bool loaded = false;
            foreach (unowned string file in files) {
                loaded |= File.new_for_path (file).equal (edited_file);
            }
            if (!loaded) {
                return {};
            }

            copy = write_editor_copy (edited);
            string[] args = {};
            foreach (unowned string file in files) {
                args += "-f";
                args += File.new_for_path (file).equal (edited_file) ? copy : file;
            }
            return args;
        }

        private string write_editor_copy (string original) throws Error {
            Gtk.TextIter start, end;
            editor_buffer.get_bounds (out start, out end);
            return Utils.write_hidden_copy (original, editor_buffer.get_text (start, end, true));
        }
    }
}
