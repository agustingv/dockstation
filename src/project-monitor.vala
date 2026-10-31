namespace DockStation {
    /* Keeps the state of every project in the list up to date from `docker ps`. */
    public class ProjectMonitor : Object {
        private const uint REFRESH_INTERVAL_SECONDS = 4;

        /* Time to call check () again. */
        public signal void tick ();

        /* Why the last check () failed, or null if it worked. */
        public string? error { get; private set; default = null; }

        private ProjectStore store;
        private uint source_id = 0;

        public ProjectMonitor (ProjectStore store) {
            this.store = store;
        }

        public void start () {
            if (source_id == 0) {
                source_id = Timeout.add_seconds (REFRESH_INTERVAL_SECONDS, () => {
                    tick ();
                    return Source.CONTINUE;
                });
            }
        }

        public void stop () {
            if (source_id != 0) {
                Source.remove (source_id);
                source_id = 0;
            }
        }

        /*
         * Updates the projects, and returns every Compose container, or null if Docker failed.
         * One call for every project, which also serves the open project's services.
         */
        public async GenericArray<ComposeContainer>? check () {
            try {
                var result = yield Docker.run (null, {
                    "ps", "--all",
                    "--filter", "label=com.docker.compose.project",
                    "--format", Docker.COMPOSE_PS_FORMAT,
                });
                if (result.success) {
                    error = null;
                    var containers = ComposeContainer.parse (result.stdout_text);
                    update_projects (containers);
                    return containers;
                }
                fail (result.stderr_text);
            } catch (Error e) {
                fail (e.message);
            }
            return null;
        }

        private void update_projects (GenericArray<ComposeContainer> containers) {
            var running = new HashTable<string, int> (str_hash, str_equal);
            var total = new HashTable<string, int> (str_hash, str_equal);
            foreach (var container in containers) {
                total[container.working_dir] = total[container.working_dir] + 1;
                if (container.state == "running") {
                    running[container.working_dir] = running[container.working_dir] + 1;
                }
            }
            for (uint i = 0; i < store.projects.get_n_items (); i++) {
                var project = (Project) store.projects.get_item (i);
                project.update_counts (running[project.path], total[project.path]);
            }
        }

        private void fail (string message) {
            var first_line = Utils.first_line (message) ?? "";
            if (first_line.contains ("No such file or directory")) {
                first_line = _("Docker is not installed");
            }
            error = first_line;
            for (uint i = 0; i < store.projects.get_n_items (); i++) {
                ((Project) store.projects.get_item (i)).mark_unknown ();
            }
        }
    }
}
