namespace DockStation {
    /* An address Traefik serves a container at, taken from its router labels. */
    public class TraefikRoute : Object {
        public string url { get; construct; }
        public string router { get; construct; }
        public string entrypoints { get; construct; }

        public TraefikRoute (string url, string router, string entrypoints) {
            Object (url: url, router: router, entrypoints: entrypoints);
        }

        /* "blog.localhost" or "blog.localhost/api", for compact display. */
        public string display_host {
            owned get {
                var start = url.index_of ("://");
                return start >= 0 ? url.substring (start + 3) : url;
            }
        }
    }

    /*
     * Reads the Traefik router labels of containers:
     *   traefik.http.routers.<name>.rule         Host(`blog.localhost`) && PathPrefix(`/api`)
     *   traefik.http.routers.<name>.entrypoints  websecure
     *   traefik.http.routers.<name>.tls          true
     * Values come from `docker inspect`, so ${VARIABLES} are already expanded.
     */
    namespace Traefik {
        private const string ROUTER_PREFIX = "traefik.http.routers.";

        private Regex? host_regex = null;
        private Regex? quoted_regex = null;
        private Regex? path_regex = null;

        private void init_regexes () {
            if (host_regex != null) {
                return;
            }
            try {
                host_regex = new Regex ("\\bHost\\(([^)]*)\\)");
                quoted_regex = new Regex ("[`\"']([^`\"']+)[`\"']");
                path_regex = new Regex ("\\bPath(?:Prefix)?\\([`\"']([^`\"']+)[`\"']\\)");
            } catch (RegexError e) {
                critical ("Invalid Traefik regex: %s", e.message);
            }
        }

        /* Host names in a rule: Host(`a`), Host(`a`, `b`), Host(`a`) || Host(`b`). */
        private string[] hosts_in_rule (string rule) {
            init_regexes ();
            string[] hosts = {};
            MatchInfo host_match;
            if (host_regex.match (rule, 0, out host_match)) {
                try {
                    do {
                        // GRegex keeps a pointer to the subject: it must outlive the MatchInfo.
                        var arguments = host_match.fetch (1);
                        MatchInfo quoted;
                        if (quoted_regex.match (arguments, 0, out quoted)) {
                            do {
                                var host = quoted.fetch (1).strip ();
                                if (host != "" && !(host in hosts)) {
                                    hosts += host;
                                }
                            } while (quoted.next ());
                        }
                    } while (host_match.next ());
                } catch (RegexError e) {
                }
            }
            return hosts;
        }

        private string path_in_rule (string rule) {
            init_regexes ();
            MatchInfo match;
            if (path_regex.match (rule, 0, out match)) {
                var path = match.fetch (1);
                return path == "/" ? "" : path;
            }
            return "";
        }

        private static bool uses_tls (HashTable<string, string> labels, string router, string entrypoints) {
            var prefix = ROUTER_PREFIX + router + ".tls";
            foreach (unowned string key in labels.get_keys ()) {
                if (key == prefix) {
                    return labels[key] == "true";
                }
                if (key.has_prefix (prefix + ".")) {
                    return true;   // tls.certresolver, tls.domains, tls.options…
                }
            }
            // The usual name of the HTTPS entrypoint.
            foreach (unowned string entrypoint in entrypoints.split (",")) {
                if (entrypoint.strip () == "websecure" || entrypoint.strip () == "https") {
                    return true;
                }
            }
            return false;
        }

        /* Routes of one container, HTTPS preferred when a host has both. */
        public GenericArray<TraefikRoute> routes_from_labels (HashTable<string, string> labels) {
            var routes = new GenericArray<TraefikRoute> ();
            if (labels["traefik.enable"] == "false") {
                return routes;
            }

            string[] routers = {};
            foreach (unowned string key in labels.get_keys ()) {
                if (key.has_prefix (ROUTER_PREFIX) && key.has_suffix (".rule")) {
                    routers += key.substring (ROUTER_PREFIX.length, key.length - ROUTER_PREFIX.length - ".rule".length);
                }
            }
            qsort_with_data<string> (routers, sizeof (string), (a, b) => strcmp (a, b));

            var by_address = new HashTable<string, TraefikRoute> (str_hash, str_equal);
            string[] order = {};
            foreach (unowned string router in routers) {
                var rule = labels[ROUTER_PREFIX + router + ".rule"];
                var entrypoints = labels[ROUTER_PREFIX + router + ".entrypoints"] ?? "";
                var scheme = uses_tls (labels, router, entrypoints) ? "https" : "http";
                var path = path_in_rule (rule);
                foreach (unowned string host in hosts_in_rule (rule)) {
                    var address = host + path;
                    var route = new TraefikRoute ("%s://%s".printf (scheme, address), router, entrypoints);
                    var existing = by_address[address];
                    if (existing == null) {
                        order += address;
                        by_address[address] = route;
                    } else if (scheme == "https" && existing.url.has_prefix ("http://")) {
                        by_address[address] = route;
                    }
                }
            }
            foreach (unowned string address in order) {
                routes.add (by_address[address]);
            }
            return routes;
        }

        /*
         * Inspects containers (by full or short ID) and returns their Traefik
         * routes, keyed by the IDs as given. Containers without routes are left out.
         */
        public async HashTable<string, GenericArray<TraefikRoute>> inspect (string[] container_ids, Cancellable? cancellable)
                throws Error {
            var result = new HashTable<string, GenericArray<TraefikRoute>> (str_hash, str_equal);
            if (container_ids.length == 0) {
                return result;
            }
            string[] args = {
                "inspect", "--type", "container", "--format",
                "C\t{{.Id}}\n{{range $k, $v := .Config.Labels}}L\t{{$k}}\t{{$v}}\n{{end}}"
            };
            foreach (unowned string id in container_ids) {
                args += id;
            }
            var output = yield Docker.run (null, args, cancellable);

            string? current = null;
            var labels = new HashTable<string, string> (str_hash, str_equal);
            foreach (unowned string line in (output.stdout_text + "C\n").split ("\n")) {
                var f = line.split ("\t", 3);
                if (f[0] == "C") {
                    if (current != null) {
                        var routes = routes_from_labels (labels);
                        foreach (unowned string id in container_ids) {
                            if (routes.length > 0 && current.has_prefix (id)) {
                                result[id] = routes;
                            }
                        }
                    }
                    current = f.length > 1 ? f[1] : null;
                    labels = new HashTable<string, string> (str_hash, str_equal);
                } else if (f[0] == "L" && f.length == 3 && f[1].has_prefix ("traefik.")) {
                    labels[f[1]] = f[2];
                }
            }
            return result;
        }
    }
}
