namespace DockStation {
    /* Runs docker commands for logic that changes things step by step; tests replace it. */
    public interface CommandRunner : Object {
        /* Returns true if the command exited successfully. */
        public abstract async bool run (string[] docker_args) throws Error;
    }

    /* Runs commands in a project's folder, showing them and their output in a log. */
    public class OutputRunner : Object, CommandRunner {
        private string working_dir;
        private LogView output;
        private Cancellable cancellable;

        public OutputRunner (string working_dir, LogView output, Cancellable cancellable) {
            this.working_dir = working_dir;
            this.output = output;
            this.cancellable = cancellable;
        }

        public async bool run (string[] docker_args) throws Error {
            output.append ("$ docker %s\n".printf (string.joinv (" ", docker_args)));
            int status = yield Docker.stream (working_dir, docker_args, (line) => {
                output.append (line + "\n");
            }, cancellable);
            if (status != 0) {
                output.append ("✘ " + _("Exited with status %d").printf (status) + "\n\n");
            }
            return status == 0;
        }
    }
}
