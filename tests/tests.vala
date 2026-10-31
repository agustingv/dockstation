/* Tests for the logic that needs no display or Docker. Run with `meson test -C build`. */
using DockStation;

const string ITEM = "compose.db.yaml";
const string RULE = "traefik.http.routers.blog.rule";
const string ENTRYPOINTS = "traefik.http.routers.blog.entrypoints";

private void eq (string? actual, string? expected) {
    assert_cmpstr (actual, CompareOperator.EQ, expected);
}

private void eq_int (int64 actual, int64 expected) {
    assert_cmpint ((int) actual, CompareOperator.EQ, (int) expected);
}

private void eq_list (string[] actual, string[] expected) {
    eq (string.joinv ("|", actual), string.joinv ("|", expected));
}

private HashTable<string, string> table (string[] pairs) {
    var result = new HashTable<string, string> (str_hash, str_equal);
    for (int i = 0; i + 1 < pairs.length; i += 2) {
        result[pairs[i]] = pairs[i + 1];
    }
    return result;
}

private GenericArray<TraefikRoute> routes (string[] pairs) {
    return Traefik.routes_from_labels (table (pairs));
}

private void add_include_tests () {
    Test.add_func ("/include/add/after-name", () => {
        eq (ServiceAdder.add_include ("name: blog\n\nservices:\n  app: {}\n", ITEM),
            "name: blog\n\ninclude:\n  - compose.db.yaml\n\nservices:\n  app: {}\n");
    });
    Test.add_func ("/include/add/name-without-blank-line", () => {
        eq (ServiceAdder.add_include ("name: blog\nservices:\n  app: {}\n", ITEM),
            "name: blog\n\ninclude:\n  - compose.db.yaml\n\nservices:\n  app: {}\n");
    });
    Test.add_func ("/include/add/before-services", () => {
        eq (ServiceAdder.add_include ("services:\n  app: {}\n", ITEM),
            "include:\n  - compose.db.yaml\n\nservices:\n  app: {}\n");
    });
    Test.add_func ("/include/add/keeps-list-indentation", () => {
        eq (ServiceAdder.add_include ("include:\n    - a.yaml # note\n\nservices:\n  app: {}\n", ITEM),
            "include:\n    - a.yaml # note\n    - compose.db.yaml\n\nservices:\n  app: {}\n");
    });
    Test.add_func ("/include/add/after-nested-keys", () => {
        eq (ServiceAdder.add_include ("include:\n  - path: a.yaml\n    env_file: b.env\nservices:\n  app: {}\n", ITEM),
            "include:\n  - path: a.yaml\n    env_file: b.env\n  - compose.db.yaml\nservices:\n  app: {}\n");
    });
    Test.add_func ("/include/add/unindented-list", () => {
        eq (ServiceAdder.add_include ("include:\n- a.yaml\nservices:\n  app: {}\n", ITEM),
            "include:\n- a.yaml\n- compose.db.yaml\nservices:\n  app: {}\n");
    });
    Test.add_func ("/include/add/refuses-flow-list", () => {
        assert (ServiceAdder.add_include ("include: [a.yaml]\nservices: {}\n", ITEM) == null);
    });
    Test.add_func ("/include/add/accepts-comment-after-key", () => {
        eq (ServiceAdder.add_include ("include: # mine\n  - a.yaml\n", ITEM),
            "include: # mine\n  - a.yaml\n  - compose.db.yaml\n");
    });
}

private void remove_include_tests () {
    Test.add_func ("/include/remove/keeps-other-items", () => {
        eq (ServiceRemover.remove_include ("include:\n  - a.yaml\n  - compose.db.yaml\nservices: {}\n", ITEM),
            "include:\n  - a.yaml\nservices: {}\n");
    });
    Test.add_func ("/include/remove/removes-empty-list", () => {
        eq (ServiceRemover.remove_include ("include:\n  - compose.db.yaml\n\nservices:\n  app: {}\n", ITEM),
            "services:\n  app: {}\n");
    });
    Test.add_func ("/include/remove/relative-prefix", () => {
        eq (ServiceRemover.remove_include ("include:\n  - a.yaml\n  - ./compose.db.yaml\n", ITEM),
            "include:\n  - a.yaml\n");
    });
    Test.add_func ("/include/remove/quotes-and-comment", () => {
        eq (ServiceRemover.remove_include ("include:\n  - a.yaml\n  - \"compose.db.yaml\" # db\n", ITEM),
            "include:\n  - a.yaml\n");
    });
    Test.add_func ("/include/remove/missing-item", () => {
        assert (ServiceRemover.remove_include ("include:\n  - a.yaml\n", ITEM) == null);
        assert (ServiceRemover.remove_include ("services: {}\n", ITEM) == null);
    });
    Test.add_func ("/include/remove/undoes-add", () => {
        foreach (unowned string text in new string[] {
                "name: blog\n\nservices:\n  app: {}\n",
                "services:\n  app: {}\n",
                "include:\n  - a.yaml\n\nservices:\n  app: {}\n" }) {
            eq (ServiceRemover.remove_include (ServiceAdder.add_include (text, ITEM), ITEM), text);
        }
    });
}

private void env_tests () {
    Test.add_func ("/env/remove-block", () => {
        eq (ServiceRemover.remove_env_block ("A=1\n\n# my-db\nMY_DB_PASSWORD=x\nMY_DB_PORT=1\nB=2\n", "my-db"),
            "A=1\nB=2\n");
    });
    Test.add_func ("/env/remove-block-absent", () => {
        const string TEXT = "A=1\nMY_DB_PASSWORD=x\n";
        eq (ServiceRemover.remove_env_block (TEXT, "my-db"), TEXT);
    });
    Test.add_func ("/env/remove-block-keeps-other-variables", () => {
        eq (ServiceRemover.remove_env_block ("# db\nDB_PORT=1\nOTHER=2\n", "db"), "OTHER=2\n");
    });
    Test.add_func ("/env/parse-line", () => {
        string key, value;
        assert (Utils.parse_env_line ("  export A_B = some value  ", out key, out value));
        eq (key, "A_B");
        eq (value, "some value");
        assert (Utils.parse_env_line ("EMPTY=", out key, out value));
        eq (value, "");
        assert (!Utils.parse_env_line ("# A=1", out key, out value));
        assert (!Utils.parse_env_line ("=1", out key, out value));
        assert (!Utils.parse_env_line ("", out key, out value));
    });
    Test.add_func ("/env/compose-files", () => {
        try {
            var dir = temp_project ();
            var env = Path.build_filename (dir, ".env");
            FileUtils.set_contents (env, "# COMPOSE_FILE=ignored.yaml\nexport COMPOSE_PATH_SEPARATOR=;\nCOMPOSE_FILE=\"a.yaml;/abs/b.yaml\"\n");
            eq_list (new Project ("p", dir).compose_files (), { dir + "/a.yaml", "/abs/b.yaml" });
            FileUtils.unlink (env);
            DirUtils.remove (dir);
        } catch (Error e) {
            error (e.message);
        }
    });
    Test.add_func ("/env/keys", () => {
        eq_list (Utils.env_keys ("# comment\nA=1\nexport B=2\n\nNOT_A_VARIABLE\n =x\nC = 3\n"), { "A", "B", "C" });
    });
}

private void traefik_tests () {
    Test.add_func ("/traefik/host-and-path", () => {
        var found = routes ({ RULE, "Host(`blog.localhost`) && PathPrefix(`/api`)" });
        eq_int (found.length, 1);
        eq (found[0].url, "http://blog.localhost/api");
        eq (found[0].router, "blog");
        eq (found[0].display_host, "blog.localhost/api");
    });
    Test.add_func ("/traefik/root-path-is-dropped", () => {
        eq (routes ({ RULE, "Host(`blog.localhost`) && Path(`/`)" })[0].url, "http://blog.localhost");
    });
    Test.add_func ("/traefik/several-hosts", () => {
        var found = routes ({ RULE, "Host(`a.localhost`) || Host(`b.localhost`, `a.localhost`)" });
        eq_int (found.length, 2);
        eq (found[0].url, "http://a.localhost");
        eq (found[1].url, "http://b.localhost");
    });
    Test.add_func ("/traefik/https-from-tls-label", () => {
        eq (routes ({ RULE, "Host(`a`)", "traefik.http.routers.blog.tls", "true" })[0].url, "https://a");
        eq (routes ({ RULE, "Host(`a`)", "traefik.http.routers.blog.tls.certresolver", "le" })[0].url, "https://a");
        eq (routes ({ RULE, "Host(`a`)", "traefik.http.routers.blog.tls", "false" })[0].url, "http://a");
    });
    Test.add_func ("/traefik/https-from-entrypoint", () => {
        eq (routes ({ RULE, "Host(`a`)", ENTRYPOINTS, "web, websecure" })[0].url, "https://a");
        eq (routes ({ RULE, "Host(`a`)", ENTRYPOINTS, "web" })[0].url, "http://a");
    });
    Test.add_func ("/traefik/prefers-https-for-the-same-address", () => {
        var found = routes ({
            "traefik.http.routers.a.rule", "Host(`x`)",
            "traefik.http.routers.b.rule", "Host(`x`)",
            "traefik.http.routers.b.tls", "true",
        });
        eq_int (found.length, 1);
        eq (found[0].url, "https://x");
        eq (found[0].router, "b");
    });
    Test.add_func ("/traefik/disabled", () => {
        eq_int (routes ({ RULE, "Host(`a`)", "traefik.enable", "false" }).length, 0);
    });
}

private void utils_tests () {
    Test.add_func ("/utils/slugify", () => {
        eq (Utils.slugify ("Mi Proyecto_2.0"), "mi-proyecto-2-0");
        eq (Utils.slugify ("  Café  "), "cafe");
        eq (Utils.slugify ("***"), "");
    });
    Test.add_func ("/utils/compose-project-name", () => {
        eq (Utils.project_name_from_folder ("My App_1"), "myapp_1");
        eq (Utils.project_name_from_folder ("-_x-y"), "x-y");
    });
    Test.add_func ("/utils/parse-size", () => {
        eq_int (Utils.parse_size ("0B"), 0);
        eq_int (Utils.parse_size ("512kB"), 512000);
        eq_int (Utils.parse_size (" 1.5 GB "), 1500000000);
        eq_int (Utils.parse_size ("N/A"), -1);
        eq_int (Utils.parse_size ("12XB"), -1);
    });
    Test.add_func ("/utils/ports", () => {
        const string PORTS = "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp, 127.0.0.1:53->53/udp";
        eq (Utils.simplify_ports (PORTS), "8080 → 80/tcp, 53 → 53/udp");
        eq_int (Utils.first_host_port (PORTS), 8080);
        eq (Utils.simplify_ports ("80/tcp"), "");
        eq_int (Utils.first_host_port ("80/tcp"), 0);
    });
    Test.add_func ("/utils/to-array", () => {
        var items = new GenericArray<string> ();
        eq_int (Utils.to_array (items).length, 0);
        items.add ("a");
        items.add ("b");
        eq_list (Utils.to_array (items), { "a", "b" });
    });
    Test.add_func ("/utils/first-line", () => {
        eq (Utils.first_line ("\n  first  \nsecond\n"), "first");
        assert (Utils.first_line (" \n ") == null);
    });
    Test.add_func ("/utils/strip-terminal-codes", () => {
        eq (Utils.strip_terminal_codes ("\x1b[2Kdb-1  | ready"), "db-1  | ready");
        eq (Utils.strip_terminal_codes ("\x1b[1;32mok\x1b[0m \x1b[?25lend"), "ok end");
        eq (Utils.strip_terminal_codes ("plain [2K text"), "plain [2K text");
    });
    Test.add_func ("/utils/read-text", () => {
        try {
            FileIOStream stream;
            var file = File.new_tmp ("dockstation-XXXXXX", out stream);
            file.replace_contents ("name: blog\n".data, null, false, FileCreateFlags.NONE, null);
            var missing = file.get_parent ().get_child (file.get_basename () + ".missing");

            string? text = null;
            bool reported_missing = false;
            var loop = new MainLoop ();
            Utils.read_text.begin (file, (obj, res) => {
                try {
                    text = Utils.read_text.end (res);
                } catch (Error e) {
                    assert_not_reached ();
                }
                Utils.read_text.begin (missing, (obj2, res2) => {
                    try {
                        Utils.read_text.end (res2);
                    } catch (IOError.NOT_FOUND e) {
                        reported_missing = true;
                    } catch (Error e) {
                        assert_not_reached ();
                    }
                    loop.quit ();
                });
            });
            loop.run ();
            file.delete ();
            eq (text, "name: blog\n");
            assert (reported_missing);
        } catch (Error e) {
            assert_not_reached ();
        }
    });
    Test.add_func ("/utils/without-handler", () => {
        var source = new SimpleAction ("test", null);
        int calls = 0;
        var handler = source.activate.connect (() => calls++);
        Utils.without_handler (source, handler, () => source.activate (null));
        assert (calls == 0);
        source.activate (null);
        assert (calls == 1);
    });
    Test.add_func ("/utils/split-lines", () => {
        eq_list (Utils.split_lines ("a\n\n  b  \n"), { "a", "b" });
    });
    Test.add_func ("/utils/random-secret", () => {
        try {
            var first = Utils.random_secret (24);
            eq_int (first.length, 24);
            assert (Regex.match_simple ("^[A-Za-z2-9]+$", first));
            assert (first != Utils.random_secret (24));
        } catch (Error e) {
            error (e.message);
        }
    });
    Test.add_func ("/utils/safe-relative-path", () => {
        foreach (unowned string good in new string[] { "public", "a/b.txt", "./a", "a..b" }) {
            assert (ServiceAdder.is_safe_relative_path (good));
        }
        foreach (unowned string bad in new string[] { "", "/etc", "..", "../a", "a/../b", "a b", "a;b" }) {
            assert (!ServiceAdder.is_safe_relative_path (bad));
        }
    });
}

private void docker_tests () {
    Test.add_func ("/docker/container-state", () => {
        foreach (unowned string name in new string[] { "created", "running", "restarting", "paused", "removing", "exited", "dead" }) {
            eq (ContainerState.parse (name).docker_name (), name);
        }
        assert (ContainerState.parse ("something-new") == ContainerState.UNKNOWN);
        eq (ContainerState.RUNNING.to_css_class (), "success");
        eq (ContainerState.PAUSED.to_css_class (), "warning");
        eq (ContainerState.DEAD.to_css_class (), "error");
        eq (ContainerState.EXITED.to_css_class (), "dim-label");
        eq (ContainerState.UNKNOWN.to_css_class (), "dim-label");
    });
    Test.add_func ("/docker/mount-type", () => {
        assert (MountType.parse ("volume") == MountType.VOLUME);
        assert (MountType.parse ("bind") == MountType.BIND);
        assert (MountType.parse ("tmpfs") == MountType.OTHER);
    });
    Test.add_func ("/docker/usage-type-names", () => {
        eq (UsageType.CONTAINERS.docker_name (), "Containers");
        eq (UsageType.IMAGES.docker_name (), "Images");
        eq (UsageType.VOLUMES.docker_name (), "Local Volumes");
        eq (UsageType.BUILD_CACHE.docker_name (), "Build Cache");
    });
    Test.add_func ("/docker/parse-containers", () => {
        var containers = ComposeContainer.parse (
            "/p\tweb\tFalse\trunning\tUp 2 hours\t0.0.0.0:80->80/tcp\tabc\n"
            + "/p\tweb\tTrue\texited\tExited\t\tone-off\n"
            + "/p\tdb\t\texited\tExited (0)\t\tdef\n"
            + "too\tshort\n");
        eq_int (containers.length, 2);
        eq (containers[0].working_dir, "/p");
        eq (containers[0].service, "web");
        assert (containers[0].state == ContainerState.RUNNING);
        eq (containers[0].id, "abc");
        eq (containers[1].service, "db");
    });
}

private string temp_project () {
    try {
        return DirUtils.make_tmp ("dockstation-test-XXXXXX");
    } catch (Error e) {
        error (e.message);
    }
}

private void inspect_tests () {
    Test.add_func ("/inspect/parse", () => {
        var containers = ContainerDetails.parse (
            "C\tabc123\tsha256:img\n"
            + "M\tvolume\tdb-data\t/var/lib/docker/x\t/var/lib/mysql\n"
            + "M\tbind\t<no value>\t/host/init\t/docker-entrypoint-initdb.d\n"
            + "E\tPGDATA=/data=1\n"
            + "E\tNOT_A_VARIABLE\n"
            + "L\ttraefik.http.routers.a.rule\tHost(`a`)\twith tab\n"
            + "C\tdef456\tsha256:other\n"
            + "stray line\n");
        eq_int (containers.length, 2);
        var first = containers[0];
        eq (first.id, "abc123");
        eq (first.image_id, "sha256:img");
        eq_int (first.mounts.length, 2);
        eq (first.mounts[0].name, "db-data");
        eq (first.mounts[1].name, "");
        eq (first.mounts[1].destination, "/docker-entrypoint-initdb.d");
        eq (first.environment["PGDATA"], "/data=1");
        eq_int (first.environment.size (), 1);
        eq (first.labels["traefik.http.routers.a.rule"], "Host(`a`)\twith tab");
        eq (containers[1].id, "def456");
        eq_int (containers[1].mounts.length, 0);
    });
    Test.add_func ("/inspect/database", () => {
        try {
            var dir = temp_project ();
            var script = Path.build_filename (dir, "01.sql");
            var other = Path.build_filename (dir, "notes.txt");
            FileUtils.set_contents (script, "");
            FileUtils.set_contents (other, "");

            var output = "C\tabc\timg\nM\tvolume\tdata\t/x\t/var/lib/postgresql/data\nM\tbind\t<no value>\t%s\t/docker-entrypoint-initdb.d\n".printf (dir);
            var database = DatabaseInit.from_container (ContainerDetails.parse (output)[0]);
            assert (database != null);
            eq (database.engine, "PostgreSQL");
            eq (database.image_id, "img");
            assert (database.data_type == MountType.VOLUME);
            eq (database.data_volume, "data");
            eq_list (database.init_files, { script });

            // Custom data folder, named by PGDATA.
            output = "C\tabc\timg\nM\tbind\t<no value>\t/host\t/pg\nM\tvolume\tinit\t/y\t/docker-entrypoint-initdb.d\nE\tPGDATA=/pg\n";
            database = DatabaseInit.from_container (ContainerDetails.parse (output)[0]);
            assert (database != null);
            eq (database.data_source, "/host");
            eq_list (database.init_volumes, { "init" });

            // No init scripts, or no data folder: nothing to reset.
            output = "C\tabc\timg\nM\tvolume\tdata\t/x\t/var/lib/mysql\n";
            assert (DatabaseInit.from_container (ContainerDetails.parse (output)[0]) == null);
            output = "C\tabc\timg\nM\tvolume\tinit\t/y\t/docker-entrypoint-initdb.d\n";
            assert (DatabaseInit.from_container (ContainerDetails.parse (output)[0]) == null);

            FileUtils.unlink (script);
            FileUtils.unlink (other);
            DirUtils.remove (dir);
        } catch (Error e) {
            error (e.message);
        }
    });
}

/* Records commands instead of running them. Commands containing `fail_on` report failure. */
private class FakeRunner : Object, CommandRunner {
    public string[] commands = {};
    public string? fail_on = null;
    public string? throw_on = null;

    public async bool run (string[] docker_args) throws Error {
        var command = string.joinv (" ", docker_args).replace ("compose --ansi never --progress plain ", "compose ");
        commands += command;
        if (throw_on != null && command.contains (throw_on)) {
            throw new IOError.FAILED ("thrown");
        }
        return fail_on == null || !command.contains (fail_on);
    }
}

private DatabaseInit database_in_volume (string volume = "blog_db-data") {
    var database = new DatabaseInit ();
    database.image_id = "sha256:img";
    database.engine = "PostgreSQL";
    database.data_type = MountType.VOLUME;
    database.data_volume = volume;
    return database;
}

private DatabaseInit database_in_folder (string folder) {
    var database = database_in_volume ("");
    database.data_type = MountType.BIND;
    database.data_source = folder;
    return database;
}

const string PROJECT = "/srv/blog";

private async void check_reset (DatabaseInit database, string? fail_on, bool expected, string[] expected_commands) {
    var runner = new FakeRunner () { fail_on = fail_on };
    try {
        var result = yield DatabaseReset.run (runner, "db", database, PROJECT);
        assert (result == expected);
    } catch (Error e) {
        error (e.message);
    }
    eq (string.joinv ("\n", runner.commands), string.joinv ("\n", expected_commands));
}

private void wait_for_reset (DatabaseInit database, string? fail_on, bool expected, string[] expected_commands) {
    var loop = new MainLoop ();
    check_reset.begin (database, fail_on, expected, expected_commands, (obj, res) => {
        check_reset.end (res);
        loop.quit ();
    });
    loop.run ();
}

private void database_reset_tests () {
    Test.add_func ("/reset/named-volume", () => {
        wait_for_reset (database_in_volume (), null, true, { "compose stop db", "compose rm --force --volumes db", "volume rm blog_db-data", "compose up --detach db" });
    });
    Test.add_func ("/reset/unnamed-volume-goes-with-the-container", () => {
        wait_for_reset (database_in_volume ("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"), null, true,
                        { "compose stop db", "compose rm --force --volumes db", "compose up --detach db" });
    });
    Test.add_func ("/reset/folder-is-emptied-inside-the-image", () => {
        wait_for_reset (database_in_folder ("/srv/blog/data"), null, true, {
            "compose stop db", "compose rm --force --volumes db",
            "run --rm --entrypoint sh --volume /srv/blog/data:/reset sha256:img -c find /reset -mindepth 1 -delete",
            "compose up --detach db",
        });
    });
    // The point of the order: a container that is still there keeps its data.
    Test.add_func ("/reset/failed-stop-touches-nothing", () => {
        wait_for_reset (database_in_volume (), "compose stop", false, { "compose stop db" });
    });
    Test.add_func ("/reset/failed-removal-keeps-the-data", () => {
        wait_for_reset (database_in_volume (), "compose rm", false, { "compose stop db", "compose rm --force --volumes db" });
    });
    Test.add_func ("/reset/failed-emptying-still-starts-the-service", () => {
        wait_for_reset (database_in_volume (), "volume rm", false, { "compose stop db", "compose rm --force --volumes db", "volume rm blog_db-data", "compose up --detach db" });
    });
    Test.add_func ("/reset/failed-start-is-a-failure", () => {
        wait_for_reset (database_in_volume (), "compose up", false, { "compose stop db", "compose rm --force --volumes db", "volume rm blog_db-data", "compose up --detach db" });
    });
    Test.add_func ("/reset/unsafe-folders-are-refused", () => {
        var home = Environment.get_home_dir ();
        foreach (unowned string folder in new string[] { "/", home, Path.get_dirname (home), PROJECT, "/srv" }) {
            assert (DatabaseReset.unsafe_data_folder (database_in_folder (folder), PROJECT) != null);

            var runner = new FakeRunner ();
            var loop = new MainLoop ();
            bool refused = false;
            DatabaseReset.run.begin (runner, "db", database_in_folder (folder), PROJECT, (obj, res) => {
                try {
                    DatabaseReset.run.end (res);
                } catch (IOError.INVALID_ARGUMENT e) {
                    refused = true;
                } catch (Error e) {
                    error (e.message);
                }
                loop.quit ();
            });
            loop.run ();
            assert (refused);
            eq_int (runner.commands.length, 0);
        }
        foreach (unowned string folder in new string[] { "/srv/blog/data", "/var/lib/db", home + "/data" }) {
            assert (DatabaseReset.unsafe_data_folder (database_in_folder (folder), PROJECT) == null);
        }
        assert (DatabaseReset.unsafe_data_folder (database_in_volume (), PROJECT) == null);
    });
    Test.add_func ("/reset/descriptions", () => {
        eq (DatabaseReset.storage_description (database_in_volume ("x")), "the volume “x”");
        eq (DatabaseReset.storage_description (database_in_volume ("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")), "an unnamed volume");
        eq (DatabaseReset.storage_description (database_in_folder ("/srv/d")), "the folder “/srv/d”");
    });
}

private class RemovalFixture {
    public string dir;
    public string main;
    public string service_file;
    public string env;
    public ServiceRemoval removal;

    public RemovalFixture () throws Error {
        dir = temp_project ();
        main = Path.build_filename (dir, "compose.yaml");
        service_file = Path.build_filename (dir, "compose.db.yaml");
        env = Path.build_filename (dir, ".env");
        FileUtils.set_contents (main, "old main");
        FileUtils.set_contents (service_file, "service");
        FileUtils.set_contents (env, "old env");
        removal = new ServiceRemoval ();
        removal.service = "db";
        removal.main_path = main;
        removal.new_main = "new main";
        removal.service_file = File.new_for_path (service_file);
        removal.env_file = File.new_for_path (env);
        removal.new_env = "new env";
        removal.volumes = { "vol1", "vol2" };
    }

    public string text (string path) throws Error {
        string contents;
        FileUtils.get_contents (path, out contents);
        return contents;
    }

    public void clean () {
        foreach (unowned string file in new string[] { main, service_file, env }) {
            FileUtils.unlink (file);
        }
        DirUtils.remove (dir);
    }
}

private delegate void RemovalCheck (RemovalFixture fixture, FakeRunner runner, string[] problems, string? failure) throws Error;

private void check_removal (string? fail_on, string? throw_on, bool delete_data, RemovalCheck check) {
    try {
        var fixture = new RemovalFixture ();
        var runner = new FakeRunner () { fail_on = fail_on, throw_on = throw_on };
        var loop = new MainLoop ();
        string[] problems = {};
        string? failure = null;
        ServiceRemover.remove.begin (runner, fixture.removal, delete_data, (obj, res) => {
            try {
                ServiceRemover.remove.end (res, out problems);
            } catch (Error e) {
                failure = e.message;
            }
            loop.quit ();
        });
        loop.run ();
        check (fixture, runner, problems, failure);
        fixture.clean ();
    } catch (Error e) {
        error (e.message);
    }
}

private void service_removal_tests () {
    Test.add_func ("/removal/keeps-data-by-default", () => {
        check_removal (null, null, false, (fixture, runner, problems, failure) => {
            assert (failure == null);
            eq_list (runner.commands, { "compose rm --stop --force --volumes db" });
            eq (fixture.text (fixture.main), "new main");
            eq (fixture.text (fixture.env), "new env");
            assert (!FileUtils.test (fixture.service_file, FileTest.EXISTS));
        });
    });
    Test.add_func ("/removal/deletes-volumes-after-the-container", () => {
        check_removal (null, null, true, (fixture, runner, problems, failure) => {
            assert (failure == null);
            eq_int (problems.length, 0);
            eq_list (runner.commands, { "compose rm --stop --force --volumes db", "volume rm vol1", "volume rm vol2" });
        });
    });
    // The files still name the service, so the user can try again.
    Test.add_func ("/removal/failed-container-changes-nothing", () => {
        check_removal ("compose rm", null, true, (fixture, runner, problems, failure) => {
            assert (failure != null && failure.contains ("db"));
            eq_list (runner.commands, { "compose rm --stop --force --volumes db" });
            eq (fixture.text (fixture.main), "old main");
            eq (fixture.text (fixture.env), "old env");
            assert (FileUtils.test (fixture.service_file, FileTest.EXISTS));
        });
    });
    Test.add_func ("/removal/failed-volume-is-reported-and-the-rest-goes-on", () => {
        check_removal ("vol1", null, true, (fixture, runner, problems, failure) => {
            assert (failure == null);
            eq_int (problems.length, 1);
            assert (problems[0].contains ("vol1"));
            eq_list (runner.commands, { "compose rm --stop --force --volumes db", "volume rm vol1", "volume rm vol2" });
            eq (fixture.text (fixture.main), "new main");
        });
    });
    Test.add_func ("/removal/volume-error-is-reported-too", () => {
        check_removal (null, "vol2", true, (fixture, runner, problems, failure) => {
            assert (failure == null);
            eq_list (problems, { "thrown" });
            eq (fixture.text (fixture.main), "new main");
        });
    });
}

private void overlay_tests () {
    Test.add_func ("/overlay/replaces-file-keeping-the-others", () => {
        try {
            var dir = temp_project ();
            var main = Path.build_filename (dir, "compose.yaml");
            var other = Path.build_filename (dir, "compose.override.yaml");
            var overlay = new ComposeOverlay ({ main, other });
            assert (overlay.loads (main));
            assert (!overlay.loads (Path.build_filename (dir, "elsewhere.yaml")));
            assert (!overlay.has_copies);

            overlay.replace_file (main, "edited");
            assert (overlay.has_copies);
            var args = overlay.compose_args ({ "config", "--quiet" });
            var joined = string.joinv (" ", args);
            assert (joined.has_prefix ("compose --ansi never --progress plain -f " + dir + "/."));
            assert (joined.has_suffix (" -f " + other + " config --quiet"));

            var copy = args[6];
            string text;
            FileUtils.get_contents (copy, out text);
            eq (text, "edited");
            eq (overlay.restore_paths ("error in %s, see %s".printf (copy, Path.get_basename (copy))),
                "error in %s, see compose.yaml".printf (main));

            overlay.remove ();
            assert (!FileUtils.test (copy, FileTest.EXISTS));
            DirUtils.remove (dir);
        } catch (Error e) {
            error (e.message);
        }
    });
    Test.add_func ("/overlay/env-only-leaves-file-discovery-to-compose", () => {
        try {
            var dir = temp_project ();
            var env = Path.build_filename (dir, ".env");
            var overlay = new ComposeOverlay ({ Path.build_filename (dir, "compose.yaml") });
            overlay.replace_env (env, "A=1\n");
            var args = overlay.compose_args ({ "config" });
            eq_list (args[0:5], { "compose", "--ansi", "never", "--progress", "plain" });
            eq (args[5], "--env-file");
            eq (args[7], "config");
            eq_int (args.length, 8);
            overlay.remove ();
            DirUtils.remove (dir);
        } catch (Error e) {
            error (e.message);
        }
    });
    Test.add_func ("/overlay/nothing-replaced", () => {
        var args = new ComposeOverlay ({ "/p/compose.yaml" }).compose_args ({ "config" });
        eq_list (args, { "compose", "--ansi", "never", "--progress", "plain", "config" });
    });
}

private void added_services_tests () {
    Test.add_func ("/services/added", () => {
        try {
            var dir = temp_project ();
            var main = Path.build_filename (dir, "compose.yaml");
            var db = Path.build_filename (dir, "compose.db.yaml");
            var web = Path.build_filename (dir, "compose.web-1.yaml");
            FileUtils.set_contents (main, "include:\n  - compose.db.yaml\n  - ./compose.web-1.yaml\n"
                                    + "  - compose.missing.yaml\n  - other.yaml\n");
            FileUtils.set_contents (db, "");
            FileUtils.set_contents (web, "");
            eq_list (ServiceRemover.added_services (new Project ("p", dir)), { "db", "web-1" });
            foreach (unowned string file in new string[] { main, db, web }) {
                FileUtils.unlink (file);
            }
            DirUtils.remove (dir);
        } catch (Error e) {
            error (e.message);
        }
    });
}

private void service_template_tests () {
    Test.add_func ("/templates/names", () => {
        eq (ServiceTemplate.env_prefix ("my-db_2"), "MY_DB_2");
        eq (ServiceTemplate.port_var ("my-db"), "MY_DB_PORT");
        eq (ServiceTemplate.volume_name ("db"), "db-data");
        assert (ServiceTemplate.is_valid_service_name ("db-1_a"));
        assert (!ServiceTemplate.is_valid_service_name ("1db"));
        assert (!ServiceTemplate.is_valid_service_name ("Db"));
        eq (ServiceTemplate.compose_file_name ("db"), "compose.db.yaml");
    });
    Test.add_func ("/templates/substitute", () => {
        try {
            eq (ServiceTemplate.substitute ("{{A}}-{{B_2}}-{{a}}", table ({ "A", "1", "B_2", "2" })), "1-2-{{a}}");
        } catch (Error e) {
            error (e.message);
        }
    });
    Test.add_func ("/templates/substitute-unknown", () => {
        try {
            ServiceTemplate.substitute ("{{MISSING}}", table ({}));
            assert_not_reached ();
        } catch (Error e) {
            assert (e.message.contains ("MISSING"));
        }
    });
    // A placeholder nobody fills in is an error, which would stop the project from being created.
    Test.add_func ("/templates/project-templates-write", () => {
        var vars = table ({
            "NAME", "My App", "NAME_HTML", "My App", "SLUG", "my-app", "PORT", "8080", "PASSWORD", "secret",
            "UID", "1000", "GID", "1000", "PHP_VERSION", "8.4", "COMPOSER_INSTALL", "",
        });
        var templates = Templates.all ();
        assert (templates.length > 0);
        foreach (var template in templates) {
            try {
                var dir = temp_project ();
                template.write_to (File.new_for_path (dir), vars);
                var compose = Path.build_filename (dir, "compose.yaml");
                string text;
                FileUtils.get_contents (compose, out text);
                assert (!text.contains ("{{"));
                Process.spawn_command_line_sync ("rm -rf " + Shell.quote (dir));
            } catch (Error e) {
                error ("%s: %s", template.name, e.message);
            }
        }
    });
    // Mistakes in a built-in service would otherwise only show up when a user adds it.
    Test.add_func ("/templates/built-in-services-render", () => {
        string[] problems;
        var templates = ServiceTemplates.load_all (out problems);
        eq_list (problems, {});
        assert (templates.length > 0);
        foreach (var template in templates) {
            var options = new HashTable<string, string> (str_hash, str_equal);
            foreach (var option in template.options) {
                options[option.key] = "value";
            }
            foreach (var version in template.versions) {
                try {
                    var vars = ServiceAdder.placeholders ("svc", version, options);
                    foreach (var host_port in new int[] { 0, 8080 }) {
                        var compose = template.render_compose (vars, "svc", host_port);
                        assert (compose.contains ("services:"));
                        assert (!compose.contains ("{{"));
                        assert (!template.render_env (vars, "svc", host_port).contains ("{{"));
                    }
                    for (int i = 0; i < template.file_paths.length; i++) {
                        assert (ServiceAdder.is_safe_relative_path (ServiceTemplate.substitute (template.file_paths[i], vars)));
                        ServiceTemplate.substitute (template.file_contents[i], vars);
                    }
                } catch (Error e) {
                    error ("%s %s: %s", template.id, version.name, e.message);
                }
            }
        }
    });
}

int main (string[] args) {
    Test.init (ref args);
    add_include_tests ();
    remove_include_tests ();
    env_tests ();
    traefik_tests ();
    utils_tests ();
    docker_tests ();
    database_reset_tests ();
    service_removal_tests ();
    inspect_tests ();
    overlay_tests ();
    added_services_tests ();
    service_template_tests ();
    return Test.run ();
}
