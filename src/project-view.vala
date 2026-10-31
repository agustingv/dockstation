namespace DockStation {
    public class ProjectView : Adw.BreakpointBin {
        public Project project { get; construct; }

        public signal void toast (string message);
        public signal void remove_requested ();
        /* Emitted after the project was deleted from disk; the view must be discarded. */
        public signal void deleted ();
        public signal void containers_changed ();

        private const string[] COMPOSE_ACTIONS = { "up", "stop", "restart", "down", "pull", "build", "down-volumes", "recreate", "delete" };

        private Cancellable cancellable = new Cancellable ();
        private SimpleActionGroup actions;
        private bool busy = false;

        private Adw.ViewStack stack;
        private Adw.ViewStackPage output_stack_page;
        private Adw.Spinner spinner;
        private Adw.Banner folder_banner;

        private ServicesPage services;
        private EditorPage editor;
        private LogsPage logs;
        private LogView output_view;
        private OutputRunner output_runner;

        public ProjectView (Project project) {
            Object (project: project);
        }

        public bool has_unsaved_changes {
            get { return editor.has_unsaved_changes; }
        }

        public string editing_file_name {
            owned get { return editor.editing_file_name; }
        }

        public async bool save_file () {
            return yield editor.save_file ();
        }

        construct {
            width_request = 360;
            height_request = 300;

            setup_actions ();
            build_ui ();

            editor.reload_files ();
            reload ();
        }

        /* Must be called before the view is discarded, to stop background processes. */
        public void shutdown () {
            cancellable.cancel ();
            services.shutdown ();
            editor.shutdown ();
            logs.stop ();
        }

        public void reload () {
            refresh_services.begin (true);
            editor.rescan_dockerfiles.begin ();
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
            add_simple_action ("add-service", () => show_add_service.begin ());

            insert_action_group ("project", actions);

            var shortcuts = new Gtk.ShortcutController ();
            shortcuts.add_shortcut (new Gtk.Shortcut (
                Gtk.ShortcutTrigger.parse_string ("<Control>s"),
                new Gtk.NamedAction ("editor.save-file")
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

        private void set_busy (bool value) {
            busy = value;
            spinner.visible = value;
            output_stack_page.needs_attention = value;
            foreach (unowned string name in COMPOSE_ACTIONS) {
                set_action_enabled (name, !value);
            }
            services.set_actions_sensitive (!value);
        }

        /* Returns true if the command ran and exited successfully. An empty `success_message` shows no toast. */
        public async bool run_compose (owned string[] args, string success_message, string failure_message) {
            if (busy) {
                return false;
            }
            bool folder_exists = project.folder_exists;
            if (folder_exists && project.find_compose_file () == null) {
                toast (_("No compose file found in %s").printf (Utils.home_relative (project.path)));
                return false;
            }

            set_busy (true);
            bool success = false;
            try {
                string[] docker_args;
                if (folder_exists) {
                    docker_args = Docker.compose_args (args);
                    output_view.append ("$ docker compose %s\n".printf (string.joinv (" ", args)));
                } else {
                    // Without its folder, Compose cannot run: act on the containers directly.
                    var folderless = yield Docker.folderless_args (project.path, args, cancellable);
                    if (folderless == null) {
                        set_busy (false);
                        toast (_("The project folder no longer exists"));
                        return false;
                    }
                    docker_args = folderless;
                    if (docker_args.length > 0) {
                        output_view.append ("$ docker %s\n".printf (string.joinv (" ", docker_args)));
                    }
                }

                int status = docker_args.length == 0 ? 0 : yield Docker.stream (folder_exists ? project.path : null, docker_args, (line) => {
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
            yield finish_commands ();
            return success;
        }

        /* What the view does after running commands that may have changed the containers. */
        private async void finish_commands () {
            set_busy (false);
            containers_changed ();
            yield refresh_services (false);
            if (logs.started) {
                logs.restart ();
            }
        }

        private async void confirm_down_volumes () {
            if (yield Dialogs.confirm (this,
                    _("Remove Containers and Volumes?"),
                    _("This runs “docker compose down --volumes”. All data stored in the project’s named volumes will be permanently deleted."),
                    _("_Remove"))) {
                yield run_compose ({ "down", "--volumes" }, _("Containers and volumes removed"), _("Could not take the project down"));
            }
        }

        /*
         * Creates every container again from its image. Fixes what Start and Restart cannot,
         * because Docker only sets it when a container is created: its DNS configuration,
         * network attachments and hostname.
         */
        private async void confirm_recreate () {
            if (yield Dialogs.confirm (this,
                    _("Recreate Containers?"),
                    _("The containers are created again from their images and started. Data in volumes and project folders is kept; changes made inside the containers are lost."),
                    _("_Recreate"), Adw.ResponseAppearance.SUGGESTED)) {
                // --remove-orphans also removes containers of services that no longer exist.
                yield run_compose ({ "up", "--detach", "--force-recreate", "--remove-orphans" },
                                   _("Containers recreated"), _("Could not recreate the containers"));
            }
        }

        private async void delete_project () {
            bool folder_exists = project.folder_exists;
            // Without the folder, the containers can still be removed, but not the images and named volumes.
            bool can_remove_containers = folder_exists ? project.find_compose_file () != null : project.total > 0;

            var containers_row = new Adw.SwitchRow () {
                title = _("Remove Containers and Volumes"),
                subtitle = folder_exists
                    ? _("Also deletes locally built images and all data in the volumes, such as databases")
                    : _("The folder no longer exists: named volumes and images are kept"),
                active = can_remove_containers,
                sensitive = can_remove_containers,
            };
            var folder_row = new Adw.SwitchRow () {
                title = _("Move Folder to Trash"),
                subtitle = folder_exists ? Utils.home_relative (project.path) : _("The folder no longer exists"),
                active = folder_exists,
                sensitive = folder_exists,
            };
            var options = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE };
            options.add_css_class ("boxed-list");
            options.append (containers_row);
            options.append (folder_row);

            if (!(yield Dialogs.confirm (this,
                    _("Delete “%s”?").printf (project.name),
                    _("The project will be removed from the list. Data in volumes cannot be recovered."),
                    _("_Delete"), Adw.ResponseAppearance.DESTRUCTIVE, options))) {
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
                logs.stop ();
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
            editor.discard_changes ();
            deleted ();
        }

        private async void show_add_service () {
            if (project.compose_files ().length == 0) {
                toast (_("No compose file found in %s").printf (Utils.home_relative (project.path)));
                return;
            }
            // Adding a service changes the compose file and .env on disk.
            if (editor.has_unsaved_changes && !(yield editor.settle_unsaved_changes ())) {
                return;
            }
            var dialog = new AddServiceDialog (project, services.service_names);
            dialog.added.connect ((service, start) => on_service_added.begin (service, start));
            dialog.present (this);
        }

        private async void on_service_added (string service, bool start) {
            toast (_("Added “%s”").printf (service));
            editor.reload_files ();
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
            services = new ServicesPage (project);
            services.reload_requested.connect (reload);
            services.service_action.connect (on_service_action);
            services.open_url.connect (open_browser);
            services.services_changed.connect (() => logs.update_services (services.service_names));

            editor = new EditorPage (project);
            editor.toast.connect ((message) => toast (message));
            editor.configuration_changed.connect (reload);
            insert_action_group ("editor", editor.actions);

            logs = new LogsPage (project);

            stack = new Adw.ViewStack () { vexpand = true };
            stack.add_titled_with_icon (services, "services", _("Services"), "view-grid-symbolic");
            stack.add_titled_with_icon (editor, "editor", _("Configuration"), "document-edit-symbolic");
            stack.add_titled_with_icon (logs, "logs", _("Logs"), "view-list-bullet-symbolic");
            output_stack_page = stack.add_titled_with_icon (build_output_page (), "output", _("Output"), "utilities-terminal-symbolic");
            stack.notify["visible-child-name"].connect (() => {
                if (stack.visible_child_name == "logs" && !logs.started) {
                    logs.restart ();
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

            folder_banner = new Adw.Banner (_("The project folder no longer exists")) {
                button_label = _("_Remove from List"),
                action_name = "project.remove",
            };

            var toolbar = new Adw.ToolbarView () { content = stack };
            toolbar.add_top_bar (header);
            toolbar.add_top_bar (folder_banner);
            toolbar.add_bottom_bar (switcher_bar);
            child = toolbar;

            var narrow = new Adw.Breakpoint (Adw.BreakpointCondition.parse ("max-width: 720sp"));
            narrow.add_setter (header, "title-widget", new Adw.WindowTitle (project.name, ""));
            narrow.add_setter (switcher_bar, "reveal", true);
            add_breakpoint (narrow);
        }

        private Gtk.Widget build_output_page () {
            output_view = new LogView ();
            output_runner = new OutputRunner (project.path, output_view, cancellable);

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

        /* ---------------------------------------------------------------- services */

        /* See ServicesPage.refresh (). */
        public async void refresh_services (bool reload_config = false, GenericArray<ComposeContainer>? containers = null) {
            folder_banner.revealed = !project.folder_exists;
            yield services.refresh (reload_config, containers);
        }

        private void on_service_action (ServiceRow row, ServiceAction action) {
            var service = row.service;
            switch (action) {
                case ServiceAction.START:
                    run_compose.begin ({ "up", "--detach", service },
                                       _("Service “%s” started").printf (service),
                                       _("Could not start “%s”").printf (service));
                    break;
                case ServiceAction.STOP:
                    run_compose.begin ({ "stop", service },
                                       _("Service “%s” stopped").printf (service),
                                       _("Could not stop “%s”").printf (service));
                    break;
                case ServiceAction.RESTART:
                    run_compose.begin ({ "restart", service },
                                       _("Service “%s” restarted").printf (service),
                                       _("Could not restart “%s”").printf (service));
                    break;
                case ServiceAction.SHOW_LOGS:
                    show_logs_for (service);
                    break;
                case ServiceAction.RESET_DATABASE:
                    if (row.database != null) {
                        reset_database.begin (service, row.database);
                    }
                    break;
                case ServiceAction.REMOVE:
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
            if (editor.has_unsaved_changes && !(yield editor.settle_unsaved_changes ())) {
                return;
            }

            ServiceRemoval removal;
            try {
                removal = yield ServiceRemover.prepare (project, service);
            } catch (Error e) {
                Dialogs.show_error (this, _("Could Not Remove the Service"), e.message);
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

            if (!(yield Dialogs.confirm (this,
                    _("Remove Service “%s”?").printf (service),
                    _("Its container is removed, and %s and its settings in .env are deleted. Files in its folders are kept.")
                        .printf (removal.service_file.get_basename ()),
                    _("_Remove"), Adw.ResponseAppearance.DESTRUCTIVE, removal.volumes.length > 0 ? options : null))) {
                return;
            }

            set_busy (true);
            string[] problems = {};
            string? failure = null;
            try {
                yield ServiceRemover.remove (output_runner, removal, data_row.active, out problems);
                output_view.append ("✔ " + _("Done") + "\n\n");
            } catch (IOError.CANCELLED e) {
                return;
            } catch (Error e) {
                failure = e.message;
            }
            yield finish_commands ();

            foreach (unowned string problem in problems) {
                toast (problem);
            }
            if (failure != null) {
                toast (failure);
                stack.visible_child_name = "output";
                return;
            }
            toast (_("Removed “%s”").printf (service));
            editor.reload_files ();
            reload ();
        }

        /* --------------------------------------------------------- database reset */

        private async void reset_database (string service, DatabaseInit database) {
            if (busy) {
                return;
            }
            var problem = DatabaseReset.unsafe_data_folder (database, project.path);
            if (problem != null) {
                toast (problem);
                return;
            }

            if (!(yield Dialogs.confirm (this,
                    _("Reset Database “%s”?").printf (service),
                    _("All data in this %s database, stored in %s, is deleted permanently. This cannot be undone.").printf (database.engine, DatabaseReset.storage_description (database))
                    + "\n\n" + _("The database is then created again, running its init scripts:") + DatabaseReset.scripts_description (database),
                    _("_Reset Database")))) {
                return;
            }

            set_busy (true);
            stack.visible_child_name = "output";
            output_view.append ("# " + _("Resetting the “%s” database").printf (service) + "\n");
            bool success = false;
            try {
                success = yield DatabaseReset.run (output_runner, service, database, project.path);
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

        private void show_logs_for (string service) {
            logs.show_service (service);
            stack.visible_child_name = "logs";
        }
    }
}
