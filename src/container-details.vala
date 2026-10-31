namespace DockStation {
    public enum MountType {
        OTHER,
        VOLUME,
        BIND;

        public static MountType parse (string name) {
            switch (name) {
                case "volume": return VOLUME;
                case "bind": return BIND;
                default: return OTHER;
            }
        }
    }

    public class ContainerMount {
        public MountType mount_type;
        public string name;         // The volume's name; empty for bind mounts
        public string source;
        public string destination;
    }

    /* What `docker inspect` says about a container, for DatabaseInit and Traefik. */
    public class ContainerDetails {
        // Mounts come back as maps: bind mounts have no "Name" key, hence `index`.
        private const string FORMAT =
            "C\t{{.Id}}\t{{.Image}}\n"
            + "{{range .Mounts}}M\t{{.Type}}\t{{index . \"Name\"}}\t{{.Source}}\t{{.Destination}}\n{{end}}"
            + "{{range .Config.Env}}E\t{{.}}\n{{end}}"
            + "{{range $k, $v := .Config.Labels}}L\t{{$k}}\t{{$v}}\n{{end}}";

        public string id;
        public string image_id;
        public GenericArray<ContainerMount> mounts = new GenericArray<ContainerMount> ();
        public HashTable<string, string> environment = new HashTable<string, string> (str_hash, str_equal);
        public HashTable<string, string> labels = new HashTable<string, string> (str_hash, str_equal);

        /* Inspects containers (by full or short ID); the result is keyed by the IDs as given. */
        public static async HashTable<string, ContainerDetails> inspect (string[] container_ids, Cancellable? cancellable)
                throws Error {
            var result = new HashTable<string, ContainerDetails> (str_hash, str_equal);
            if (container_ids.length == 0) {
                return result;
            }
            string[] args = { "inspect", "--type", "container", "--format", FORMAT };
            foreach (unowned string id in container_ids) {
                args += id;
            }
            // Partial output is still useful if a container disappeared meanwhile.
            var output = yield Docker.run (null, args, cancellable);
            foreach (var container in parse (output.stdout_text)) {
                foreach (unowned string id in container_ids) {
                    if (container.id.has_prefix (id)) {
                        result[id] = container;
                    }
                }
            }
            return result;
        }

        public static GenericArray<ContainerDetails> parse (string output) {
            var containers = new GenericArray<ContainerDetails> ();
            ContainerDetails? current = null;
            foreach (unowned string line in output.split ("\n")) {
                var f = line.split ("\t");
                if (f[0] == "C" && f.length >= 3) {
                    current = new ContainerDetails ();
                    current.id = f[1];
                    current.image_id = f[2];
                    containers.add (current);
                } else if (current != null && f[0] == "M" && f.length >= 5) {
                    var mount = new ContainerMount ();
                    mount.mount_type = MountType.parse (f[1]);
                    mount.name = f[2] == "<no value>" ? "" : f[2];
                    mount.source = f[3];
                    mount.destination = f[4];
                    current.mounts.add (mount);
                } else if (current != null && f[0] == "E" && f.length >= 2) {
                    var variable = line.substring (2);
                    var equals = variable.index_of ("=");
                    if (equals > 0) {
                        current.environment[variable.substring (0, equals)] = variable.substring (equals + 1);
                    }
                } else if (current != null && f[0] == "L" && f.length >= 3) {
                    var label = line.split ("\t", 3);
                    current.labels[label[1]] = label[2];
                }
            }
            return containers;
        }
    }
}
