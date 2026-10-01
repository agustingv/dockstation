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

    /* One line of `docker ps --format Docker.COMPOSE_PS_FORMAT`. */
    public class ComposeContainer {
        public string working_dir;
        public string service;
        public string state;
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
                container.state = f[3];
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
    public class Docker : Object {
        private static bool? sandboxed = null;

        private static bool in_flatpak () {
            if (sandboxed == null) {
                sandboxed = FileUtils.test ("/.flatpak-info", FileTest.EXISTS);
            }
            return sandboxed;
        }

        private static Subprocess spawn (string? cwd, string[] args, SubprocessFlags flags) throws Error {
            var launcher = new SubprocessLauncher (flags);
            string[] argv = {};
            if (in_flatpak ()) {
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
        public const string COMPOSE_PS_FORMAT =
            "{{.Label \"com.docker.compose.project.working_dir\"}}\t{{.Label \"com.docker.compose.service\"}}\t"
            + "{{.Label \"com.docker.compose.oneoff\"}}\t{{.State}}\t{{.Status}}\t{{.Ports}}\t{{.ID}}";

        /* Arguments for a `docker compose` command, with plain output that is easy to show. */
        public static string[] compose_args (string[] args) {
            string[] result = { "compose", "--ansi", "never", "--progress", "plain" };
            foreach (unowned string arg in args) {
                result += arg;
            }
            return result;
        }

        /* Runs a command to completion and collects its output. */
        public static async CommandResult run (string? cwd, owned string[] args, Cancellable? cancellable = null) throws Error {
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
        public static async int stream (string? cwd, owned string[] args, owned LineFunc on_line, Cancellable? cancellable = null) throws Error {
            var proc = spawn (cwd, args, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
            var input = new DataInputStream (proc.get_stdout_pipe ());
            try {
                string? line;
                while ((line = yield input.read_line_async (Priority.DEFAULT, cancellable)) != null) {
                    if (!line.validate ()) {
                        line = line.make_valid ();
                    }
                    on_line (line);
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
