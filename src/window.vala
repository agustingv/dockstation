namespace DockStation {
    public class Window : Adw.ApplicationWindow {
        private const uint REFRESH_INTERVAL_SECONDS = 4;

        private ProjectStore store;
        private Gtk.ListBox project_list;
        private Gtk.Stack sidebar_stack;
        private Adw.NavigationSplitView split_view;
        private Adw.NavigationPage content_page;
        private Gtk.Widget empty_content;
        private Adw.ToastOverlay toast_overlay;
        private Adw.Banner docker_banner;
        private ProjectView? current_view = null;
        private Gtk.ListBox tools_list;
        private Gtk.Widget tools_area;
        private AppSettings settings;
        private bool opening_tool = false;
        private ResourcesView? resources_view = null;
        private bool syncing_selection = false;
        private bool refreshing = false;
        private bool close_confirmed = false;
        private bool opening_initial_project = false;
        private uint refresh_source_id = 0;

        public Window (Application app) {
            Object (application: app);
        }

        construct {
            title = "DockStation";
            icon_name = Config.APP_ID;
            default_width = 1100;
            default_height = 720;
            width_request = 360;
            height_request = 400;

            store = new ProjectStore ();
            store.load ();
            settings = new AppSettings ();

            ActionEntry[] entries = {
                { "new-project", on_new_project },
                { "add-project", on_add_project },
                { "refresh", on_refresh },
            };
            add_action_entries (entries, this);

            var show_resources_action = new SimpleAction.stateful (
                "show-resources", null, new Variant.boolean (settings.show_resources));
            show_resources_action.change_state.connect ((action, state) => {
                action.set_state (state);
                settings.show_resources = state.get_boolean ();
                update_tools_visibility ();
            });
            add_action (show_resources_action);

            build_ui ();

            // Open the first project, like other GNOME sidebar apps, without
            // jumping to the content page when the window starts narrow.
            var first_row = project_list.get_row_at_index (0);
            if (first_row != null) {
                opening_initial_project = true;
                project_list.select_row (first_row);
                opening_initial_project = false;
            }

            refresh.begin ();
            refresh_source_id = Timeout.add_seconds (REFRESH_INTERVAL_SECONDS, () => {
                refresh.begin ();
                return Source.CONTINUE;
            });
        }

        private void build_ui () {
            // Sidebar
            var add_menu = new Menu ();
            add_menu.append (_("_New Project…"), "win.new-project");
            add_menu.append (_("_Add Existing Project…"), "win.add-project");
            var add_button = new Gtk.MenuButton () {
                icon_name = "list-add-symbolic",
                menu_model = add_menu,
                tooltip_text = _("Add Project"),
            };

            var main_menu = new Menu ();
            main_menu.append (_("_Refresh"), "win.refresh");
            main_menu.append (_("Show _Docker Resources"), "win.show-resources");
            main_menu.append (_("_About DockStation"), "app.about");
            var menu_button = new Gtk.MenuButton () {
                icon_name = "open-menu-symbolic",
                menu_model = main_menu,
                primary = true,
                tooltip_text = _("Main Menu"),
            };

            var sidebar_header = new Adw.HeaderBar ();
            sidebar_header.pack_start (add_button);
            sidebar_header.pack_end (menu_button);

            docker_banner = new Adw.Banner ("") { button_label = _("Retry") };
            docker_banner.button_clicked.connect (() => refresh.begin ());

            project_list = new Gtk.ListBox ();
            project_list.add_css_class ("navigation-sidebar");
            project_list.bind_model (store.projects, (item) => new ProjectRow ((Project) item));
            project_list.row_selected.connect (on_row_selected);

            var new_button = new Gtk.Button.with_mnemonic (_("_New Project")) {
                action_name = "win.new-project",
                halign = Gtk.Align.CENTER,
            };
            new_button.add_css_class ("pill");
            new_button.add_css_class ("suggested-action");
            var existing_button = new Gtk.Button.with_mnemonic (_("_Add Existing")) {
                action_name = "win.add-project",
                halign = Gtk.Align.CENTER,
            };
            existing_button.add_css_class ("pill");
            var empty_buttons = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            empty_buttons.append (new_button);
            empty_buttons.append (existing_button);

            var empty_sidebar = new Adw.StatusPage () {
                icon_name = "folder-new-symbolic",
                title = _("No Projects"),
                description = _("Create a new Compose project or add an existing folder"),
                child = empty_buttons,
            };
            empty_sidebar.add_css_class ("compact");

            sidebar_stack = new Gtk.Stack ();
            sidebar_stack.add_named (new Gtk.ScrolledWindow () {
                child = project_list,
                hscrollbar_policy = Gtk.PolicyType.NEVER,
                vexpand = true,
            }, "list");
            sidebar_stack.add_named (empty_sidebar, "empty");

            // Optional entries below the project list.
            var resources_row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
                margin_top = 6,
                margin_bottom = 6,
                margin_start = 6,
                margin_end = 6,
            };
            resources_row_box.append (new Gtk.Image.from_icon_name ("drive-harddisk-symbolic"));
            resources_row_box.append (new Gtk.Label (_("Docker Resources")) { xalign = 0, hexpand = true });
            tools_list = new Gtk.ListBox ();
            tools_list.add_css_class ("navigation-sidebar");
            tools_list.append (new Gtk.ListBoxRow () {
                child = resources_row_box,
                tooltip_text = _("Containers, images and volumes, and the disk space they use"),
            });
            // Open only on an explicit click or Enter: keyboard focus landing on the
            // row when the window opens must not start measuring disk usage.
            tools_list.row_selected.connect (on_tool_selected);
            tools_list.row_activated.connect (on_tool_activated);

            var tools_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            tools_box.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
            tools_box.append (tools_list);
            tools_area = tools_box;

            var sidebar_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            sidebar_box.append (sidebar_stack);
            sidebar_box.append (tools_area);

            var sidebar_toolbar = new Adw.ToolbarView () { content = sidebar_box };
            sidebar_toolbar.add_top_bar (sidebar_header);
            sidebar_toolbar.add_top_bar (docker_banner);

            // Content placeholder
            var empty_toolbar = new Adw.ToolbarView () {
                content = new Adw.StatusPage () {
                    icon_name = "view-grid-symbolic",
                    title = _("No Project Selected"),
                    description = _("Select a project to manage its services"),
                },
            };
            empty_toolbar.add_top_bar (new Adw.HeaderBar () { show_title = false });
            empty_content = empty_toolbar;

            content_page = new Adw.NavigationPage (empty_content, _("Projects"));

            split_view = new Adw.NavigationSplitView () {
                sidebar = new Adw.NavigationPage (sidebar_toolbar, "DockStation"),
                content = content_page,
                min_sidebar_width = 240,
                max_sidebar_width = 320,
            };

            toast_overlay = new Adw.ToastOverlay () { child = split_view };
            content = toast_overlay;

            var narrow = new Adw.Breakpoint (Adw.BreakpointCondition.parse ("max-width: 720sp"));
            narrow.add_setter (split_view, "collapsed", true);
            add_breakpoint (narrow);

            store.projects.items_changed.connect (update_sidebar_stack);
            update_sidebar_stack ();
            update_tools_visibility ();
        }

        private void update_tools_visibility () {
            tools_area.visible = settings.show_resources;
            // Hiding the entry while its page is open goes back to the placeholder.
            if (!settings.show_resources && tools_list.get_selected_row () != null) {
                syncing_selection = true;
                tools_list.unselect_all ();
                syncing_selection = false;
                show_project.begin (null);
            }
        }

        private void update_sidebar_stack () {
            sidebar_stack.visible_child_name = store.projects.get_n_items () > 0 ? "list" : "empty";
        }

        public void show_toast (string message) {
            toast_overlay.add_toast (new Adw.Toast (message));
        }

        /* ----------------------------------------------------------- navigation */

        private void on_row_selected (Gtk.ListBoxRow? row) {
            if (syncing_selection) {
                return;
            }
            if (row != null) {
                syncing_selection = true;
                tools_list.unselect_all ();
                syncing_selection = false;
            } else if (tools_list.get_selected_row () != null) {
                return;
            }
            var project = row != null ? ((ProjectRow) row).project : null;
            if (current_view != null && current_view.project == project) {
                return;
            }
            show_project.begin (project);
        }

        /* Selection alone (for example, from keyboard focus) is undone; see on_tool_activated. */
        private void on_tool_selected (Gtk.ListBoxRow? row) {
            if (syncing_selection || opening_tool || row == null) {
                return;
            }
            syncing_selection = true;
            tools_list.unselect_all ();
            syncing_selection = false;
        }

        private void on_tool_activated (Gtk.ListBoxRow row) {
            opening_tool = true;
            tools_list.select_row (row);
            opening_tool = false;

            syncing_selection = true;
            project_list.unselect_all ();
            syncing_selection = false;
            if (resources_view == null || content_page.child != resources_view) {
                show_resources.begin ();
            }
        }

        /*
         * Closes the open project view, asking about unsaved changes first.
         * Callers must only `yield` this when `leaving_needs_confirmation` is true:
         * yielding an async call always resumes on a later main-loop iteration,
         * and switching views has to be immediate in the common case (for example,
         * "Start After Creating" uses the new view right after selecting it).
         */
        private async void leave_project_view () {
            if (current_view == null) {
                return;
            }
            var old_view = current_view;
            current_view = null;
            if (old_view.has_unsaved_changes) {
                yield confirm_unsaved (old_view);
            }
            old_view.shutdown ();
        }

        private bool leaving_needs_confirmation {
            get { return current_view != null && current_view.has_unsaved_changes; }
        }

        private void close_project_view () {
            if (current_view != null) {
                current_view.shutdown ();
                current_view = null;
            }
        }

        private async void show_resources () {
            if (leaving_needs_confirmation) {
                yield leave_project_view ();
            } else {
                close_project_view ();
            }
            if (resources_view == null) {
                resources_view = new ResourcesView (store);
                resources_view.toast.connect (show_toast);
                resources_view.open_project.connect (select_project);
            }
            resources_view.reload ();
            content_page.child = resources_view;
            content_page.title = _("Docker Resources");
            split_view.show_content = true;
        }

        private void select_project (Project project) {
            uint position;
            if (store.projects.find (project, out position)) {
                project_list.select_row (project_list.get_row_at_index ((int) position));
            }
        }

        private async void show_project (Project? project) {
            if (leaving_needs_confirmation) {
                yield leave_project_view ();
            } else {
                close_project_view ();
            }

            if (project == null) {
                content_page.child = empty_content;
                content_page.title = _("Projects");
                return;
            }

            var view = new ProjectView (project);
            view.toast.connect (show_toast);
            view.remove_requested.connect (() => confirm_remove.begin (project));
            view.containers_changed.connect (() => refresh.begin ());
            view.deleted.connect (() => on_project_deleted.begin (project));
            current_view = view;
            content_page.child = view;
            content_page.title = project.name;
            if (!opening_initial_project) {
                split_view.show_content = true;
            }
        }

        private async void confirm_unsaved (ProjectView view) {
            // Ask again if saving fails, so changes are only lost when explicitly discarded.
            while (view.has_unsaved_changes) {
                if (!(yield ask_save_changes (view))) {
                    return;
                }
                yield view.save_file ();
            }
        }

        /* Returns true if the user chose to save. */
        private async bool ask_save_changes (ProjectView view) {
            var dialog = new Adw.AlertDialog (
                _("Save Changes?"),
                _("“%s” in “%s” has unsaved changes.").printf (view.editing_file_name, view.project.name)
            );
            dialog.add_response ("discard", _("_Discard"));
            dialog.add_response ("save", _("_Save"));
            dialog.set_response_appearance ("discard", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_response_appearance ("save", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "save";
            dialog.close_response = "save";

            return (yield dialog.choose (this, null)) == "save";
        }

        public override bool close_request () {
            if (!close_confirmed && current_view != null && current_view.has_unsaved_changes) {
                confirm_unsaved.begin (current_view, (obj, res) => {
                    confirm_unsaved.end (res);
                    close_confirmed = true;
                    close ();
                });
                return true;
            }
            if (refresh_source_id != 0) {
                Source.remove (refresh_source_id);
                refresh_source_id = 0;
            }
            if (current_view != null) {
                current_view.shutdown ();
            }
            if (resources_view != null) {
                resources_view.shutdown ();
            }
            return base.close_request ();
        }

        /* -------------------------------------------------------------- actions */

        private void on_refresh () {
            refresh.begin ();
            if (current_view != null) {
                current_view.reload ();
            }
            if (resources_view != null && content_page.child == resources_view) {
                resources_view.reload ();
            }
        }

        private void on_new_project () {
            var dialog = new NewProjectDialog (store);
            dialog.created.connect ((project, start) => {
                store.add (project);
                select_project (project);
                show_toast (_("Created “%s”").printf (project.name));
                if (start && current_view != null && current_view.project == project) {
                    current_view.run_compose.begin ({ "up", "--detach", "--build" },
                                                    _("Project started"),
                                                    _("Could not start the project"));
                }
            });
            dialog.present (this);
        }

        private void on_add_project () {
            var dialog = new Gtk.FileDialog () { title = _("Select a Docker Compose Project Folder") };
            dialog.select_folder.begin (this, null, (obj, res) => {
                try {
                    var folder = dialog.select_folder.end (res);
                    add_existing.begin (folder);
                } catch (Error e) {
                    // Dismissed by the user.
                }
            });
        }

        private async void add_existing (File folder) {
            var path = folder.get_path ();
            if (path == null) {
                show_toast (_("Only local folders are supported"));
                return;
            }

            var existing = store.find_by_path (path);
            if (existing != null) {
                select_project (existing);
                show_toast (_("“%s” is already in the list").printf (existing.name));
                return;
            }

            var name = folder.get_basename ();
            if (Project.find_compose_file_in (path) == null) {
                var dialog = new Adw.AlertDialog (
                    _("No Compose File Found"),
                    _("“%s” does not contain a compose.yaml file. Create an empty one?").printf (name)
                );
                dialog.add_response ("cancel", _("_Cancel"));
                dialog.add_response ("create", _("C_reate"));
                dialog.set_response_appearance ("create", Adw.ResponseAppearance.SUGGESTED);
                dialog.default_response = "create";
                dialog.close_response = "cancel";

                if ((yield dialog.choose (this, null)) != "create") {
                    return;
                }
                var vars = new HashTable<string, string> (str_hash, str_equal);
                vars["SLUG"] = Utils.slugify (name) != "" ? Utils.slugify (name) : "app";
                try {
                    Templates.blank ().write_to (folder, vars);
                } catch (Error e) {
                    show_toast (e.message);
                    return;
                }
            }

            var project = new Project (name, path);
            store.add (project);
            select_project (project);
            refresh.begin ();
        }

        private async void on_project_deleted (Project project) {
            store.remove (project);
            if (current_view != null && current_view.project == project) {
                yield show_project (null);
            }
            show_toast (_("Deleted “%s”").printf (project.name));
            refresh.begin ();
        }

        private async void confirm_remove (Project project) {
            var dialog = new Adw.AlertDialog (
                _("Remove “%s” from the List?").printf (project.name),
                _("The project folder, its containers and its volumes will not be deleted.")
            );
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("remove", _("_Remove from List"));
            dialog.set_response_appearance ("remove", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";

            if ((yield dialog.choose (this, null)) != "remove") {
                return;
            }
            store.remove (project);
            if (current_view != null && current_view.project == project) {
                yield show_project (null);
            }
            show_toast (_("Removed “%s”").printf (project.name));
        }

        /* -------------------------------------------------------------- status */

        private async void refresh () {
            if (refreshing) {
                return;
            }
            refreshing = true;

            try {
                // One call for every project: group all compose containers by project folder.
                var result = yield Docker.run (null, {
                    "ps", "--all",
                    "--filter", "label=com.docker.compose.project",
                    "--format", "{{.Label \"com.docker.compose.project.working_dir\"}}\t{{.State}}"
                });

                if (result.success) {
                    docker_banner.revealed = false;
                    var running = new HashTable<string, int> (str_hash, str_equal);
                    var total = new HashTable<string, int> (str_hash, str_equal);
                    foreach (unowned string line in result.stdout_text.split ("\n")) {
                        var fields = line.split ("\t");
                        if (fields.length < 2) {
                            continue;
                        }
                        total[fields[0]] = total[fields[0]] + 1;
                        if (fields[1] == "running") {
                            running[fields[0]] = running[fields[0]] + 1;
                        }
                    }
                    for (uint i = 0; i < store.projects.get_n_items (); i++) {
                        var project = (Project) store.projects.get_item (i);
                        project.update_counts (running[project.path], total[project.path]);
                    }
                } else {
                    show_docker_error (result.stderr_text);
                }
            } catch (Error e) {
                show_docker_error (e.message);
            }

            if (current_view != null) {
                yield current_view.refresh_services ();
            }
            refreshing = false;
        }

        private void show_docker_error (string message) {
            var first_line = message.strip ().split ("\n")[0] ?? "";
            if (first_line.contains ("No such file or directory")) {
                first_line = _("Docker is not installed");
            }
            docker_banner.title = Markup.escape_text (first_line);
            docker_banner.revealed = true;
            for (uint i = 0; i < store.projects.get_n_items (); i++) {
                ((Project) store.projects.get_item (i)).mark_unknown ();
            }
        }
    }
}
