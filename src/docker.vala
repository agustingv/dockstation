namespace DockStation {
    public class CommandResult : Object {
        public int status;
        public string stdout_text;
        public string stderr_text;

        public bool success {
            get { return status == 0; }
        }
    }

    public delegate void LineFunc (string line);

    /* The state Docker reports for a container. */
    public enum ContainerState {
        UNKNOWN,
        CREATED,
        RUNNING,
        RESTARTING,
        PAUSED,
        REMOVING,
        EXITED,
        DEAD;

        public static ContainerState parse (string name) {
            switch (name) {
                case "created": return CREATED;
                case "running": return RUNNING;
                case "restarting": return RESTARTING;
                case "paused": return PAUSED;
                case "removing": return REMOVING;
                case "exited": return EXITED;
                case "dead": return DEAD;
                default: return UNKNOWN;
            }
        }

        /* Docker's own name for the state. */
        public string docker_name () {
            switch (this) {
                case CREATED: return "created";
                case RUNNING: return "running";
                case RESTARTING: return "restarting";
                case PAUSED: return "paused";
                case REMOVING: return "removing";
                case EXITED: return "exited";
                case DEAD: return "dead";
                default: return "unknown";
            }
        }
    }

    /* One line of `docker ps --format COMPOSE_PS_FORMAT`. */
    public class ComposeContainer {
        public string working_dir;
        public string service;
        public ContainerState state;
        public string status;
        public string ports;
        public string id;

        /*
         * The service containers in `docker ps` output. Containers left by `docker compose run`
         * are skipped: they are not replicas of the service.
         */
        public static GenericArray<ComposeContainer> parse (string output) {
            var containers = new GenericArray<ComposeContainer> ();
            foreach (unowned string line in output.split ("\n")) {
                var f = line.split ("\t");
                if (f.length < 7 || f[2] == "True") {
                    continue;
                }
                var container = new ComposeContainer ();
                container.working_dir = f[0];
                container.service = f[1];
                container.state = ContainerState.parse (f[3]);
                container.status = f[4];
                container.ports = f[5];
                container.id = f[6];
                containers.add (container);
            }
            return containers;
        }
    }

    /*
     * Thin asynchronous wrapper around the docker CLI. When running inside
     * Flatpak, commands are forwarded to the host with flatpak-spawn.
     */
    namespace Docker {
        private Subprocess spawn (string? cwd, string[] args, SubprocessFlags flags) throws Error {
            var launcher = new SubprocessLauncher (flags);
            string[] argv = {};
            if (Utils.in_flatpak ()) {
                argv += "flatpak-spawn";
                argv += "--host";
                if (cwd != null) {
                    argv += "--directory=" + cwd;
                }
            } else if (cwd != null) {
                launcher.set_cwd (cwd);
            }
            argv += "docker";
            foreach (unowned string arg in args) {
                argv += arg;
            }
            return launcher.spawnv (argv);
        }

        /*
         * `docker ps` columns for Compose containers, split by ComposeContainer.parse ().
         * Plain `docker ps` gives the same data as `docker compose ps` at a fraction of the
         * cost, because Compose parses the project's files on every run.
         */
        private const string COMPOSE_PS_FORMAT =
            "{{.Label \"com.docker.compose.project.working_dir\"}}\t{{.Label \"com.docker.compose.service\"}}\t"
            + "{{.Label \"com.docker.compose.oneoff\"}}\t{{.State}}\t{{.Status}}\t{{.Ports}}\t{{.ID}}";

        /*
         * The Compose containers of the project in `working_dir`, or of every project if it
         * is null. Fails with IOError.FAILED, and Docker's message, if Docker reports an error.
         */
        public async GenericArray<ComposeContainer> compose_containers (string? working_dir,
                                                                                Cancellable? cancellable = null) throws Error {
            var label = "label=com.docker.compose.project";
            var filter = working_dir != null ? label + ".working_dir=" + working_dir : label;
            var result = yield run (null, { "ps", "--all", "--filter", filter, "--format", COMPOSE_PS_FORMAT }, cancellable);
            if (!result.success) {
                throw new IOError.FAILED (result.stderr_text.strip ());
            }
            return ComposeContainer.parse (result.stdout_text);
        }

        /* Arguments for a `docker compose` command, with plain output that is easy to show. */
        public string[] compose_args (string[] args) {
            string[] result = { "compose", "--ansi", "never", "--progress", "plain" };
            foreach (unowned string arg in args) {
                result += arg;
            }
            return result;
        }

        private const string[] FOLDERLESS_COMMANDS = { "stop", "down", "rm" };

        /*
         * Plain `docker` arguments doing what the compose command `args` does, for a project
         * whose folder is gone. Only stopping and removing containers is possible without the
         * files: returns null for other commands, and an empty array when there is nothing to do.
         */
        public async string[]? folderless_args (string working_dir, string[] args, Cancellable? cancellable = null) throws Error {
            if (args.length == 0 || !(args[0] in FOLDERLESS_COMMANDS)) {
                return null;
            }
            var containers = yield compose_containers (working_dir, cancellable);
            return folderless_args_for (working_dir, args, containers);
        }

        /* See folderless_args (). Containers are found by folder, not by project name, which other folders may share. */
        public string[] folderless_args_for (string working_dir, string[] args, GenericArray<ComposeContainer> containers) {
            string[] services = {};
            bool volumes = false;
            for (int i = 1; i < args.length; i++) {
                if (args[i] == "--volumes" || args[i] == "-v") {
                    volumes = true;
                } else if (args[i] == "--rmi") {
                    i++;
                } else if (!args[i].has_prefix ("-")) {
                    services += args[i];
                }
            }

            string[] ids = {};
            foreach (var container in containers) {
                if (container.working_dir != working_dir || (services.length > 0 && !(container.service in services))
                    || (args[0] == "stop" && container.state != ContainerState.RUNNING)) {
                    continue;
                }
                ids += container.id;
            }
            if (ids.length == 0) {
                return {};
            }

            string[] docker_args;
            if (args[0] == "stop") {
                docker_args = { "stop" };
            } else {
                docker_args = { "rm", "--force" };
                if (volumes) {
                    docker_args += "--volumes";
                }
            }
            foreach (unowned string id in ids) {
                docker_args += id;
            }
            return docker_args;
        }

        /* Runs a command to completion and collects its output. */
        public async CommandResult run (string? cwd, owned string[] args, Cancellable? cancellable = null) throws Error {
            var proc = spawn (cwd, args, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string? out_text = null;
            string? err_text = null;
            try {
                yield proc.communicate_utf8_async (null, cancellable, out out_text, out err_text);
            } catch (Error e) {
                proc.force_exit ();
                throw e;
            }
            var result = new CommandResult ();
            result.status = proc.get_if_exited () ? proc.get_exit_status () : -1;
            result.stdout_text = out_text ?? "";
            result.stderr_text = err_text ?? "";
            return result;
        }

        /* Runs a command, delivering stdout+stderr line by line. Returns the exit status. */
        public async int stream (string? cwd, owned string[] args, owned LineFunc on_line, Cancellable? cancellable = null) throws Error {
            var proc = spawn (cwd, args, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
            var input = new DataInputStream (proc.get_stdout_pipe ());
            try {
                string? line;
                while ((line = yield input.read_line_async (Priority.DEFAULT, cancellable)) != null) {
                    if (!line.validate ()) {
                        line = line.make_valid ();
                    }
                    on_line (Utils.strip_terminal_codes (line));
                }
            } catch (Error e) {
                // SIGTERM (not SIGKILL) so flatpak-spawn can forward it to the host process.
                proc.send_signal (ProcessSignal.TERM);
                throw e;
            }
            yield proc.wait_async (null);
            return proc.get_if_exited () ? proc.get_exit_status () : -1;
        }
    }
}
