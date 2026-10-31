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
        eq (Utils.compose_project_name ("My App_1"), "myapp_1");
        eq (Utils.compose_project_name ("-_x-y"), "x-y");
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
    Test.add_func ("/docker/parse-containers", () => {
        var containers = ComposeContainer.parse (
            "/p\tweb\tFalse\trunning\tUp 2 hours\t0.0.0.0:80->80/tcp\tabc\n"
            + "/p\tweb\tTrue\texited\tExited\t\tone-off\n"
            + "/p\tdb\t\texited\tExited (0)\t\tdef\n"
            + "too\tshort\n");
        eq_int (containers.length, 2);
        eq (containers[0].working_dir, "/p");
        eq (containers[0].service, "web");
        eq (containers[0].state, "running");
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
    overlay_tests ();
    added_services_tests ();
    service_template_tests ();
    return Test.run ();
}
