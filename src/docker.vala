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
