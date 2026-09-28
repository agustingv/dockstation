namespace DockStation {
    public class ContainerResource : Object {
        public string id;
        public string name;
        public string image;
        public string state;
        public string status;
        public string project;
        public string service;
        public string working_dir;
        public int64 size;          // Writable layer only; the image is counted separately.
    }

    public class ImageResource : Object {
        public string id;
        public string repository;
        public string tag;
        public string created;
        public int containers;
        public int64 size;          // Includes layers shared with other images.
        public int64 unique_size;   // Space freed if only this image is removed.
        private string[] project_names = {};

        /* Compose projects that built or use this image. */
        public string[] projects {
            get { return project_names; }
        }

        public string display_name {
            owned get {
                if (repository == "<none>") {
                    return "<none> (%s)".printf (short_id (id));
                }
                return tag == "<none>" ? repository : "%s:%s".printf (repository, tag);
            }
        }

        public void add_project (string project) {
            if (project != "" && !(project in project_names)) {
                project_names += project;
            }
        }
    }

    public class VolumeResource : Object {
        public string name;
        public string project;
        public string driver;
        public int links;
        public int64 size;          // -1 when Docker cannot tell (non-local drivers).
    }

    /* One line of `docker system df`: totals that count shared layers once. */
    public class UsageSummary : Object {
        public int total;
        public int active;
        public int64 size;
        public string reclaimable;
    }

    private string short_id (string id) {
        var hex = id.has_prefix ("sha256:") ? id.substring (7) : id;
        return hex.length > 12 ? hex.substring (0, 12) : hex;
    }

    /* Snapshot of the containers, images and volumes known to Docker, with their disk usage. */
    public class DockerResources : Object {
        private const string COMPOSE_PROJECT = "com.docker.compose.project";

        // Real tabs and newlines: the docker CLI rejects escaped ones inside templates.
        private const string DF_FORMAT =
            "{{range .Containers}}C\t{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}\t{{.Size}}\t"
            + "{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}\t"
            + "{{.Label \"com.docker.compose.project.working_dir\"}}\n{{end}}"
            + "{{range .Images}}I\t{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.UniqueSize}}\t{{.Containers}}\t{{.CreatedSince}}\n{{end}}"
            + "{{range .Volumes}}V\t{{.Name}}\t{{.Links}}\t{{.Size}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Driver}}\n{{end}}";
        private const string IMAGE_LABEL_FORMAT =
            "{{.Id}}\t{{with .Config.Labels}}{{index . \"com.docker.compose.project\"}}{{end}}";
        private const string SUMMARY_FORMAT =
            "{{.Type}}\t{{.TotalCount}}\t{{.Active}}\t{{.Size}}\t{{.Reclaimable}}";

        public GenericArray<ContainerResource> containers = new GenericArray<ContainerResource> ();
        public GenericArray<ImageResource> images = new GenericArray<ImageResource> ();
        public GenericArray<VolumeResource> volumes = new GenericArray<VolumeResource> ();
        /* Keyed by Docker's type names: "Images", "Containers", "Local Volumes", "Build Cache". */
        public HashTable<string, UsageSummary> summaries = new HashTable<string, UsageSummary> (str_hash, str_equal);

        public static async DockerResources load (Cancellable? cancellable = null) throws Error {
            var resources = new DockerResources ();

            var df = yield Docker.run (null, { "system", "df", "--verbose", "--format", DF_FORMAT }, cancellable);
            if (!df.success) {
                throw new IOError.FAILED (df.stderr_text.strip ().split ("\n")[0] ?? _("Could not read Docker disk usage"));
            }
            resources.parse_disk_usage (df.stdout_text);

            if (resources.images.length > 0) {
                string[] args = { "image", "inspect", "--format", IMAGE_LABEL_FORMAT };
                for (uint i = 0; i < resources.images.length; i++) {
                    args += resources.images[i].id;
                }
                var labels = yield Docker.run (null, args, cancellable);
                // Partial output is still useful if an image disappeared meanwhile.
                resources.parse_image_projects (labels.stdout_text);
            }
            resources.link_images_to_containers ();

            var summary = yield Docker.run (null, { "system", "df", "--format", SUMMARY_FORMAT }, cancellable);
            if (summary.success) {
                resources.parse_summary (summary.stdout_text);
            }
            return resources;
        }

        /* Go templates print "<no value>" for labels an object does not have. */
        private static string[] split_fields (string line) {
            var fields = line.split ("\t");
            for (int i = 0; i < fields.length; i++) {
                if (fields[i] == "<no value>") {
                    fields[i] = "";
                }
            }
            return fields;
        }

        private void parse_disk_usage (string output) {
            foreach (unowned string line in output.split ("\n")) {
                var f = split_fields (line);
                if (f[0] == "C" && f.length >= 10) {
                    var c = new ContainerResource ();
                    c.id = f[1];
                    c.name = f[2];
                    c.image = f[3];
                    c.state = f[4];
                    c.status = f[5];
                    c.size = Utils.parse_size (f[6]);
                    c.project = f[7];
                    c.service = f[8];
                    c.working_dir = f[9];
                    containers.add (c);
                } else if (f[0] == "I" && f.length >= 8) {
                    var i = new ImageResource ();
                    i.id = f[1];
                    i.repository = f[2];
                    i.tag = f[3];
                    i.size = Utils.parse_size (f[4]);
                    i.unique_size = Utils.parse_size (f[5]);
                    i.containers = int.parse (f[6]);
                    i.created = f[7];
                    images.add (i);
                } else if (f[0] == "V" && f.length >= 6) {
                    var v = new VolumeResource ();
                    v.name = f[1];
                    v.links = int.parse (f[2]);
                    v.size = Utils.parse_size (f[3]);
                    v.project = f[4];
                    v.driver = f[5];
                    volumes.add (v);
                }
            }
        }

        /* Images built by Compose carry the project label. */
        private void parse_image_projects (string output) {
            var by_id = new HashTable<string, ImageResource> (str_hash, str_equal);
            for (uint i = 0; i < images.length; i++) {
                by_id[images[i].id] = images[i];
            }
            foreach (unowned string line in output.split ("\n")) {
                var f = split_fields (line);
                if (f.length >= 2 && f[1] != "" && by_id.contains (f[0])) {
                    by_id[f[0]].add_project (f[1]);
                }
            }
        }

        /* An image also belongs to every project whose containers use it. */
        private void link_images_to_containers () {
            var by_reference = new HashTable<string, ImageResource> (str_hash, str_equal);
            for (uint i = 0; i < images.length; i++) {
                var image = images[i];
                by_reference[image.id] = image;
                by_reference[short_id (image.id)] = image;
                if (image.repository != "<none>" && image.tag != "<none>") {
                    by_reference["%s:%s".printf (image.repository, image.tag)] = image;
                }
            }
            for (uint i = 0; i < containers.length; i++) {
                var container = containers[i];
                var image = by_reference[normalize_reference (container.image)];
                if (image != null) {
                    image.add_project (container.project);
                }
            }
        }

        /* "nginx" → "nginx:latest", "docker.io/library/nginx:1" → "nginx:1" */
        private static string normalize_reference (string reference) {
            var result = reference;
            foreach (unowned string prefix in new string[] { "docker.io/library/", "docker.io/" }) {
                if (result.has_prefix (prefix)) {
                    result = result.substring (prefix.length);
                    break;
                }
            }
            if (result.has_prefix ("sha256:") || result.contains ("@")) {
                return result;
            }
            var name_start = result.last_index_of ("/") + 1;
            if (!result.substring (name_start).contains (":")) {
                result += ":latest";
            }
            return result;
        }

        private void parse_summary (string output) {
            foreach (unowned string line in output.split ("\n")) {
                var f = line.split ("\t");
                if (f.length < 5) {
                    continue;
                }
                var s = new UsageSummary ();
                s.total = int.parse (f[1]);
                s.active = int.parse (f[2]);
                s.size = Utils.parse_size (f[3]);
                // "10.94MB (96%)": format the size like the others, keep the percentage.
                var paren = f[4].index_of (" (");
                var bytes = Utils.parse_size (paren >= 0 ? f[4].substring (0, paren) : f[4]);
                s.reclaimable = bytes >= 0
                    ? Utils.format_size (bytes) + (paren >= 0 ? f[4].substring (paren) : "")
                    : f[4];
                summaries[f[0]] = s;
            }
        }
    }
}
