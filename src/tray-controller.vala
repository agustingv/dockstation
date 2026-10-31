namespace DockStation {
    /* What the tray icon shows, and what its menu does. */
    public class TrayController : Object {
        public signal void open_requested ();
        public signal void project_open_requested (Project project);
        /* A command started from the menu ended; it may have changed the project's state. */
        public signal void command_finished (Project project);

        private GLib.Application application;
        private ProjectStore store;
        private TrayIcon? tray = null;
        private bool enabled = false;
        // Projects with a command started from the tray, and what it is doing ("Starting…").
        private HashTable<string, string> busy_projects = new HashTable<string, string> (str_hash, str_equal);

        public TrayController (GLib.Application application, ProjectStore store) {
            this.application = application;
            this.store = store;
        }

        /* The icon is shown while running in the background, which is when it is useful. */
        public void update (bool enabled) {
            this.enabled = enabled;
            if (!enabled) {
                if (tray != null) {
                    tray.hide ();
                }
                return;
            }
            if (tray == null) {
                var connection = application.get_dbus_connection ();
                if (connection == null) {
                    return;
                }
                tray = new TrayIcon (connection);
                tray.item.activated.connect (() => open_requested ());
                tray.menu.item_activated.connect (on_item);
            }
            tray.item.set_description (store.running_summary ());
            tray.menu.set_items (menu_items ());
            tray.show ();
        }

        private TrayMenuItem[] menu_items () {
            TrayMenuItem[] items = { new TrayMenuItem (_("Open DockStation"), TrayAction.OPEN) };
            if (store.projects.get_n_items () > 0) {
                items += new TrayMenuItem.separator ();
            }
            for (uint i = 0; i < store.projects.get_n_items (); i++) {
                var project = (Project) store.projects.get_item (i);
                var busy = busy_projects[project.path];
                var running = project.is_running;
                var entry = new TrayMenuItem ("%s — %s".printf (TrayMenuItem.escape (project.name), busy ?? project.status_label));
                entry.children = {
                    new TrayMenuItem (_("Open"), TrayAction.OPEN_PROJECT, project),
                    new TrayMenuItem (running ? _("Stop") : _("Start"), running ? TrayAction.STOP : TrayAction.START, project) { enabled = busy == null },
                    new TrayMenuItem (_("Restart"), TrayAction.RESTART, project) { enabled = busy == null && running },
                };
                items += entry;
            }
            items += new TrayMenuItem.separator ();
            items += new TrayMenuItem (_("Quit"), TrayAction.QUIT);
            return items;
        }

        private void on_item (TrayMenuItem item) {
            var project = item.target as Project;
            switch (item.action) {
                case TrayAction.NONE:
                    break;
                case TrayAction.OPEN:
                    open_requested ();
                    break;
                case TrayAction.QUIT:
                    application.activate_action ("quit", null);
                    break;
                case TrayAction.OPEN_PROJECT:
                    project_open_requested (project);
                    break;
                case TrayAction.START:
                    run_command.begin (project, { "up", "--detach" }, _("Starting…"), _("Could not start “%s”"));
                    break;
                case TrayAction.STOP:
                    run_command.begin (project, { "stop" }, _("Stopping…"), _("Could not stop “%s”"));
                    break;
                case TrayAction.RESTART:
                    run_command.begin (project, { "restart" }, _("Restarting…"), _("Could not restart “%s”"));
                    break;
            }
        }

        /*
         * Runs a compose command for a project that may not be open, with the window possibly
         * hidden: failures are reported with a desktop notification instead of a toast.
         */
        private async void run_command (Project project, string[] args, string busy_label, string failure) {
            if (busy_projects.contains (project.path)) {
                return;
            }
            busy_projects[project.path] = busy_label;
            update (enabled);
            try {
                string[]? docker_args = Docker.compose_args (args);
                if (!project.folder_exists) {
                    docker_args = yield Docker.folderless_args (project.path, args);
                    if (docker_args == null) {
                        throw new IOError.NOT_FOUND (_("The project folder no longer exists"));
                    }
                }
                var result = docker_args.length == 0
                    ? new CommandResult ()
                    : yield Docker.run (project.folder_exists ? project.path : null, docker_args);
                if (!result.success) {
                    notify_failure (project, failure.printf (project.name), result.stderr_text);
                }
            } catch (Error e) {
                notify_failure (project, failure.printf (project.name), e.message);
            }
            busy_projects.remove (project.path);
            command_finished (project);
            update (enabled);
        }

        private void notify_failure (Project project, string title, string details) {
            var notification = new Notification (title);
            var lines = Utils.split_lines (details);
            if (lines.length > 0) {
                // Compose ends with the reason, such as "Error response from daemon: …".
                notification.set_body (lines[lines.length - 1]);
            }
            application.send_notification ("command-" + project.path, notification);
        }
    }
}
