namespace DockStation {
    /*
     * Runs Compose against changes that are not on disk yet: it loads temporary copies in
     * place of the project's files. Being next to the originals, paths relative to them
     * (include, extends) still work. Call remove () when done.
     */
    public class ComposeOverlay {
        private string[] files;
        private string[] originals = {};
        private string[] copies = {};
        private string? env_copy = null;

        /* `files` are the ones Compose loads, as in Project.compose_files (). */
        public ComposeOverlay (string[] files) {
            this.files = files;
        }

        public bool has_copies {
            get { return copies.length > 0; }
        }

        public bool loads (string path) {
            var file = File.new_for_path (path);
            foreach (unowned string loaded in files) {
                if (File.new_for_path (loaded).equal (file)) {
                    return true;
                }
            }
            return false;
        }

        public void replace_file (string path, string text) throws Error {
            add_copy (path, text);
        }

        public void replace_env (string path, string text) throws Error {
            env_copy = add_copy (path, text);
        }

        private string add_copy (string original, string text) throws Error {
            var copy = Utils.write_hidden_copy (original, text);
            originals += original;
            copies += copy;
            return copy;
        }

        private string? copy_of (string path) {
            var file = File.new_for_path (path);
            for (int i = 0; i < originals.length; i++) {
                if (File.new_for_path (originals[i]).equal (file)) {
                    return copies[i];
                }
            }
            return null;
        }

        /* Arguments for a `docker compose` command that loads the copies. */
        public string[] compose_args (string[] command) {
            string[] args = {};
            bool file_replaced = false;
            foreach (unowned string file in files) {
                file_replaced |= copy_of (file) != null;
            }
            // Without -f, Compose keeps finding the project's files on its own.
            for (int i = 0; file_replaced && i < files.length; i++) {
                args += "-f";
                args += copy_of (files[i]) ?? files[i];
            }
            if (env_copy != null) {
                args += "--env-file";
                args += env_copy;
            }
            foreach (unowned string arg in command) {
                args += arg;
            }
            return Docker.compose_args (args);
        }

        /* Compose's messages name the copies: shows the files the user knows instead. */
        public string restore_paths (string message) {
            var result = message;
            for (int i = 0; i < copies.length; i++) {
                result = result.replace (copies[i], originals[i])
                    .replace (Path.get_basename (copies[i]), Path.get_basename (originals[i]));
            }
            return result;
        }

        public void remove () {
            foreach (unowned string copy in copies) {
                FileUtils.unlink (copy);
            }
            originals = {};
            copies = {};
            env_copy = null;
        }
    }
}
