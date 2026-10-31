namespace DockStation {
    /*
     * Empties a database's data and starts it again, so its image's entrypoint runs
     * the init scripts as on the first start. See DatabaseInit.
     */
    namespace DatabaseReset {
        private const int MAX_LISTED_SCRIPTS = 8;

        /* Refuses to empty folders that obviously hold more than the database. */
        public string? unsafe_data_folder (DatabaseInit database, string project_path) {
            if (database.data_type != MountType.BIND) {
                return null;
            }
            var folder = File.new_for_path (database.data_source);
            var home = File.new_for_path (Environment.get_home_dir ());
            var project_folder = File.new_for_path (project_path);
            if (folder.get_parent () == null || folder.equal (home) || folder.equal (project_folder)
                || home.has_prefix (folder) || project_folder.has_prefix (folder)) {
                return _("The data folder “%s” is not a dedicated database folder, so it will not be emptied.")
                    .printf (Utils.home_relative (database.data_source));
            }
            return null;
        }

        /* Where the data is, to complete a sentence: "the volume “x”". */
        public string storage_description (DatabaseInit database) {
            if (database.data_type == MountType.BIND) {
                return _("the folder “%s”").printf (Utils.home_relative (database.data_source));
            }
            if (database.data_is_anonymous_volume) {
                return _("an unnamed volume");
            }
            return _("the volume “%s”").printf (database.data_volume);
        }

        /* The scripts that will run, one line each, each line starting with a newline. */
        public string scripts_description (DatabaseInit database) {
            string scripts = "";
            for (int i = 0; i < database.init_files.length && i < MAX_LISTED_SCRIPTS; i++) {
                scripts += "\n• " + Path.get_basename (database.init_files[i]);
            }
            if (database.init_files.length > MAX_LISTED_SCRIPTS) {
                scripts += "\n• " + _("and %d more").printf (database.init_files.length - MAX_LISTED_SCRIPTS);
            }
            foreach (unowned string volume in database.init_volumes) {
                scripts += "\n• " + _("the scripts in the volume “%s”").printf (volume);
            }
            return scripts;
        }

        /*
         * Returns true if the database was reset. The data is only touched once its container
         * is gone. Fails, without running anything, if the data folder is not safe to empty.
         */
        public async bool run (CommandRunner runner, string service, DatabaseInit database, string project_path)
                throws Error {
            var problem = unsafe_data_folder (database, project_path);
            if (problem != null) {
                throw new IOError.INVALID_ARGUMENT (problem);
            }

            // --volumes also drops an unnamed data volume.
            if (!(yield runner.run (Docker.compose_args ({ "stop", service })))
                || !(yield runner.run (Docker.compose_args ({ "rm", "--force", "--volumes", service })))) {
                return false;
            }

            bool emptied = true;
            if (database.data_type == MountType.VOLUME && !database.data_is_anonymous_volume) {
                emptied = yield runner.run ({ "volume", "rm", database.data_volume });
            } else if (database.data_type == MountType.BIND) {
                // Run as root inside the database image: the files belong to its user.
                emptied = yield runner.run ({
                    "run", "--rm", "--entrypoint", "sh", "--volume", database.data_source + ":/reset",
                    database.image_id, "-c", "find /reset -mindepth 1 -delete"
                });
            }

            // Start it again even after a failure, so the service is not left down.
            bool started = yield runner.run (Docker.compose_args ({ "up", "--detach", service }));
            return emptied && started;
        }
    }
}
