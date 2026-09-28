namespace DockStation {
    /* Shows Docker's containers, images and volumes grouped by project, with their disk usage. */
    public class ResourcesView : Adw.BreakpointBin {
        public signal void toast (string message);
        public signal void open_project (Project project);

        private enum GroupOrder {
            PROJECT,
            SHARED,
            OTHER,
            UNUSED,
        }

        /* Rows of one group while a page is being built. */
        private class Bucket {
            public string title;
            public Project? project;
            public string compose_name;
            public GroupOrder order;
            public int64 total = 0;
            public GenericArray<Gtk.Widget> rows = new GenericArray<Gtk.Widget> ();
            private GenericArray<Entry> entries = new GenericArray<Entry> ();

            private class Entry {
                public Gtk.Widget row;
                public int64 size;
            }

            public void add (Gtk.Widget row, int64 size) {
                var entry = new Entry ();
                entry.row = row;
                entry.size = size;
                entries.add (entry);
                total += int64.max (size, 0);
            }

            /* Largest first. */
            public void sort_rows () {
                entries.sort ((a, b) => a.size < b.size ? 1 : (a.size > b.size ? -1 : 0));
                rows = new GenericArray<Gtk.Widget> ();
                for (uint i = 0; i < entries.length; i++) {
                    rows.add (entries[i].row);
                }
            }
        }

        private ProjectStore store;
        private DockerResources? data = null;
        private Cancellable? loading = null;
        private bool busy = false;

        private Gtk.Stack state_stack;
        private Adw.StatusPage error_page;
        private Adw.ViewStack stack;
        private Adw.Bin containers_bin;
        private Adw.Bin images_bin;
        private Adw.Bin volumes_bin;
        private Adw.Spinner spinner;
        private Gtk.SearchBar search_bar;
        private Gtk.SearchEntry search_entry;
        private HashTable<string, Project> projects_by_compose_name;

        public ResourcesView (ProjectStore store) {
            this.store = store;
            width_request = 360;
            height_request = 300;
            build_ui ();
        }

        public void shutdown () {
            if (loading != null) {
                loading.cancel ();
            }
        }

        public void reload () {
            load.begin ();
        }

        /* --------------------------------------------------------------------- UI */

        private void build_ui () {
            containers_bin = new Adw.Bin ();
            images_bin = new Adw.Bin ();
            volumes_bin = new Adw.Bin ();

            stack = new Adw.ViewStack () { vexpand = true };
            stack.add_titled_with_icon (containers_bin, "containers", _("Containers"), "view-grid-symbolic");
            stack.add_titled_with_icon (images_bin, "images", _("Images"), "package-x-generic-symbolic");
            stack.add_titled_with_icon (volumes_bin, "volumes", _("Volumes"), "drive-harddisk-symbolic");

            var loading_page = new Adw.StatusPage () {
                title = _("Calculating Disk Usage…"),
                description = _("Docker is measuring containers, images and volumes"),
            };
            loading_page.paintable = new Adw.SpinnerPaintable (loading_page);

            error_page = new Adw.StatusPage () {
                icon_name = "dialog-warning-symbolic",
                title = _("Could Not Read Docker Resources"),
            };
            var retry_button = new Gtk.Button.with_mnemonic (_("_Retry")) { halign = Gtk.Align.CENTER };
            retry_button.add_css_class ("pill");
            retry_button.clicked.connect (reload);
            error_page.child = retry_button;

            state_stack = new Gtk.Stack ();
            state_stack.add_named (loading_page, "loading");
            state_stack.add_named (error_page, "error");
            state_stack.add_named (stack, "content");

            search_entry = new Gtk.SearchEntry () {
                placeholder_text = _("Search by name, image or project"),
                hexpand = true,
            };
            search_entry.search_changed.connect (render);
            var clamp = new Adw.Clamp () { child = search_entry, maximum_size = 500 };
            search_bar = new Gtk.SearchBar () { child = clamp, key_capture_widget = this };
            search_bar.connect_entry (search_entry);

            var search_button = new Gtk.ToggleButton () {
                icon_name = "system-search-symbolic",
                tooltip_text = _("Search"),
            };
            search_button.bind_property ("active", search_bar, "search-mode-enabled",
                                         BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

            var refresh_button = new Gtk.Button.from_icon_name ("view-refresh-symbolic") { tooltip_text = _("Refresh") };
            refresh_button.clicked.connect (reload);

            spinner = new Adw.Spinner () { visible = false };

            var header = new Adw.HeaderBar () {
                title_widget = new Adw.ViewSwitcher () { stack = stack, policy = Adw.ViewSwitcherPolicy.WIDE },
            };
            header.pack_start (refresh_button);
            header.pack_end (search_button);
            header.pack_end (spinner);

            var switcher_bar = new Adw.ViewSwitcherBar () { stack = stack };

            var toolbar = new Adw.ToolbarView () { content = state_stack };
            toolbar.add_top_bar (header);
            toolbar.add_top_bar (search_bar);
            toolbar.add_bottom_bar (switcher_bar);
            child = toolbar;

            var narrow = new Adw.Breakpoint (Adw.BreakpointCondition.parse ("max-width: 720sp"));
            narrow.add_setter (header, "title-widget", new Adw.WindowTitle (_("Docker Resources"), ""));
            narrow.add_setter (switcher_bar, "reveal", true);
            add_breakpoint (narrow);
        }

        /* ---------------------------------------------------------------- loading */

        private async void load () {
            if (loading != null) {
                loading.cancel ();
            }
            var cancellable = new Cancellable ();
            loading = cancellable;

            spinner.visible = true;
            if (data == null) {
                state_stack.visible_child_name = "loading";
            }

            try {
                var resources = yield DockerResources.load (cancellable);
                if (cancellable.is_cancelled ()) {
                    return;
                }
                data = resources;
                render ();
                state_stack.visible_child_name = "content";
            } catch (IOError.CANCELLED e) {
                return;
            } catch (Error e) {
                if (data == null) {
                    error_page.description = e.message;
                    state_stack.visible_child_name = "error";
                } else {
                    toast (e.message);
                }
            }
            spinner.visible = false;
        }

        /* Maps Compose project names to the projects in DockStation's list. */
        private void index_projects () {
            projects_by_compose_name = new HashTable<string, Project> (str_hash, str_equal);
            // Containers record the folder they were started from: the most reliable link.
            for (uint i = 0; i < data.containers.length; i++) {
                var c = data.containers[i];
                var project = c.working_dir != "" ? store.find_by_path (c.working_dir) : null;
                if (c.project != "" && project != null) {
                    projects_by_compose_name[c.project] = project;
                }
            }
            // Otherwise, the name Compose derives from the folder name.
            for (uint i = 0; i < store.projects.get_n_items (); i++) {
                var project = (Project) store.projects.get_item (i);
                var name = Utils.compose_project_name (Path.get_basename (project.path));
                if (!projects_by_compose_name.contains (name)) {
                    projects_by_compose_name[name] = project;
                }
            }
        }

        /* -------------------------------------------------------------- rendering */

        private void render () {
            if (data == null) {
                return;
            }
            index_projects ();
            containers_bin.child = build_containers_page ();
            images_bin.child = build_images_page ();
            volumes_bin.child = build_volumes_page ();
        }

        private bool matches (string[] fields) {
            var query = search_entry.text.strip ().down ();
            if (query == "") {
                return true;
            }
            foreach (unowned string field in fields) {
                if (field.down ().contains (query)) {
                    return true;
                }
            }
            return false;
        }

        private Bucket get_bucket (HashTable<string, Bucket> buckets, string key, string title,
                                   GroupOrder order, string compose_name = "") {
            var bucket = buckets[key];
            if (bucket == null) {
                bucket = new Bucket ();
                bucket.order = order;
                bucket.compose_name = compose_name;
                bucket.project = compose_name != "" ? projects_by_compose_name[compose_name] : null;
                bucket.title = bucket.project != null ? bucket.project.name : title;
                buckets[key] = bucket;
            }
            return bucket;
        }

        private Bucket project_bucket (HashTable<string, Bucket> buckets, string compose_name) {
            return get_bucket (buckets, "project:" + compose_name, compose_name, GroupOrder.PROJECT, compose_name);
        }

        private static Gtk.Label size_label (int64 bytes) {
            var label = new Gtk.Label (Utils.format_size (bytes)) { valign = Gtk.Align.CENTER };
            label.add_css_class ("numeric");
            label.add_css_class ("dim-label");
            return label;
        }

        private static Adw.ActionRow resource_row (string title, string subtitle, int64 size) {
            var row = new Adw.ActionRow () {
                title = Markup.escape_text (title),
                subtitle = Markup.escape_text (subtitle),
                subtitle_lines = 2,
            };
            row.add_suffix (size_label (size));
            return row;
        }

        private Gtk.Widget build_page (HashTable<string, Bucket> buckets, Adw.PreferencesGroup summary,
                                       string empty_title, string empty_icon) {
            var list = buckets.get_values ();
            if (list.length () == 0) {
                var searching = search_entry.text.strip () != "";
                return new Adw.StatusPage () {
                    icon_name = searching ? "system-search-symbolic" : empty_icon,
                    title = searching ? _("No Results Found") : empty_title,
                    description = searching ? _("Try a different search") : null,
                };
            }

            list.sort ((a, b) => {
                if (a.order != b.order) {
                    return (int) a.order - (int) b.order;
                }
                return a.total < b.total ? 1 : (a.total > b.total ? -1 : 0);
            });

            var page = new Adw.PreferencesPage ();
            page.add (summary);
            foreach (var bucket in list) {
                bucket.sort_rows ();
                var group = new Adw.PreferencesGroup () { title = Markup.escape_text (bucket.title) };
                var description = ngettext ("%d item", "%d items", bucket.rows.length).printf (bucket.rows.length)
                    + " · " + Utils.format_size (bucket.total);
                if (bucket.project != null && bucket.compose_name != "" && bucket.compose_name != bucket.project.name) {
                    description += " · " + _("Compose project “%s”").printf (bucket.compose_name);
                }
                group.description = Markup.escape_text (description);

                if (bucket.project != null) {
                    var project = bucket.project;
                    var open_button = new Gtk.Button.from_icon_name ("go-next-symbolic") {
                        tooltip_text = _("Open Project"),
                        valign = Gtk.Align.CENTER,
                    };
                    open_button.add_css_class ("flat");
                    open_button.clicked.connect (() => open_project (project));
                    group.header_suffix = open_button;
                }

                for (uint i = 0; i < bucket.rows.length; i++) {
                    group.add (bucket.rows[i]);
                }
                page.add (group);
            }
            return page;
        }

        private Adw.PreferencesGroup summary_group (string docker_type, string description) {
            var group = new Adw.PreferencesGroup () { description = description };
            var summary = data.summaries[docker_type];
            if (summary == null) {
                return group;
            }
            add_property (group, _("Total Size"), Utils.format_size (summary.size));
            add_property (group, _("In Use"), _("%d of %d").printf (summary.active, summary.total));
            add_property (group, _("Reclaimable"), summary.reclaimable);
            return group;
        }

        private string reclaimable (string docker_type) {
            var summary = data.summaries[docker_type];
            return summary != null ? summary.reclaimable : _("unknown");
        }

        private static Adw.ActionRow add_property (Adw.PreferencesGroup group, string title, string value) {
            var row = new Adw.ActionRow () { title = title };
            var label = new Gtk.Label (value) { valign = Gtk.Align.CENTER, selectable = true };
            label.add_css_class ("numeric");
            row.add_suffix (label);
            group.add (row);
            return row;
        }

        /* ---------------------------------------------------------------- cleanup */

        /* Containers `docker container prune` removes. */
        private static bool is_stopped (ContainerResource container) {
            return container.state == "exited" || container.state == "created" || container.state == "dead";
        }

        private static Gtk.Button trash_button (string tooltip) {
            var button = new Gtk.Button.from_icon_name ("user-trash-symbolic") {
                tooltip_text = tooltip,
                valign = Gtk.Align.CENTER,
            };
            button.add_css_class ("flat");
            return button;
        }

        private static Gtk.Button cleanup_button (string label) {
            var button = new Gtk.Button.with_mnemonic (label) { valign = Gtk.Align.CENTER };
            button.add_css_class ("destructive-action");
            return button;
        }

        private async bool confirm (string heading, string body, string action_label) {
            var dialog = new Adw.AlertDialog (heading, body);
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("remove", action_label);
            dialog.set_response_appearance ("remove", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            return (yield dialog.choose (this, null)) == "remove";
        }

        private void set_busy (bool value) {
            busy = value;
            spinner.visible = value;
            // Tabs stay usable; only the buttons in the pages are blocked.
            containers_bin.sensitive = !value;
            images_bin.sensitive = !value;
            volumes_bin.sensitive = !value;
        }

        /* "Total reclaimed space: 1.2GB" (prune) or "Total:  1.2GB" (builder prune). */
        private static int64 reclaimed_space (string output) {
            foreach (unowned string line in output.split ("\n")) {
                var trimmed = line.strip ();
                if (trimmed.has_prefix ("Total reclaimed space:") || trimmed.has_prefix ("Total:")) {
                    return Utils.parse_size (trimmed.substring (trimmed.index_of (":") + 1));
                }
            }
            return -1;
        }

        private async void run_cleanup (owned string[] args, string success_message) {
            if (busy) {
                return;
            }
            set_busy (true);
            try {
                var result = yield Docker.run (null, args, null);
                if (result.success) {
                    var freed = reclaimed_space (result.stdout_text);
                    toast (freed > 0
                        ? _("%s · %s freed").printf (success_message, Utils.format_size (freed))
                        : success_message);
                } else {
                    toast (result.stderr_text.strip ().split ("\n")[0] ?? _("The command failed"));
                }
            } catch (Error e) {
                toast (e.message);
            }
            set_busy (false);
            reload ();
        }

        private async void remove_container (ContainerResource container) {
            var body = container.project != ""
                ? _("The stopped container is removed. Its image and volumes are kept, and the project creates it again the next time it starts.")
                : _("The stopped container is removed, including any changes made inside it. Its image and volumes are kept.");
            if (yield confirm (_("Remove Container “%s”?").printf (container.name), body, _("_Remove"))) {
                yield run_cleanup ({ "container", "rm", container.id }, _("Removed “%s”").printf (container.name));
            }
        }

        private async void remove_image (ImageResource image) {
            var body = image.projects.length > 0
                ? _("The project will pull or build it again the next time it starts.")
                : _("If it came from a registry, it can be downloaded again. Images built on this computer have to be built again.");
            if (image.unique_size > 0) {
                body += " " + _("Frees about %s.").printf (Utils.format_size (image.unique_size));
            }
            // A tag removes just that name; an ID is needed for untagged images.
            var reference = image.repository != "<none>" && image.tag != "<none>"
                ? "%s:%s".printf (image.repository, image.tag)
                : image.id;
            if (yield confirm (_("Remove Image “%s”?").printf (image.display_name), body, _("_Remove"))) {
                yield run_cleanup ({ "image", "rm", reference }, _("Removed “%s”").printf (image.display_name));
            }
        }

        private async void remove_volume (VolumeResource volume) {
            var body = _("All data stored in it, such as databases, is deleted permanently. This cannot be undone.");
            if (volume.size > 0) {
                body += " " + _("Frees %s.").printf (Utils.format_size (volume.size));
            }
            if (yield confirm (_("Delete Volume “%s”?").printf (volume.name), body, _("_Delete"))) {
                yield run_cleanup ({ "volume", "rm", volume.name }, _("Deleted “%s”").printf (volume.name));
            }
        }

        private async void prune_containers (int count) {
            if (yield confirm (
                    ngettext ("Remove %d Stopped Container?", "Remove All %d Stopped Containers?", count).printf (count),
                    _("Docker estimates %s can be freed. Images and volumes are kept, and projects can create their containers again.").printf (reclaimable ("Containers")),
                    _("_Remove"))) {
                yield run_cleanup ({ "container", "prune", "--force" }, _("Stopped containers removed"));
            }
        }

        private async void prune_images (int count) {
            if (yield confirm (
                    ngettext ("Remove %d Unused Image?", "Remove All %d Unused Images?", count).printf (count),
                    _("Removes every image that no container uses, including images built by your projects; they are pulled or built again when needed. Docker estimates %s can be freed.").printf (reclaimable ("Images")),
                    _("_Remove"))) {
                yield run_cleanup ({ "image", "prune", "--all", "--force" }, _("Unused images removed"));
            }
        }

        private async void prune_volumes (int count) {
            if (yield confirm (
                    ngettext ("Delete %d Unused Volume?", "Delete All %d Unused Volumes?", count).printf (count),
                    _("All data in these volumes, such as databases, is deleted permanently. This cannot be undone. Volumes attached to a container, even a stopped one, are kept. Docker estimates %s can be freed.").printf (reclaimable ("Local Volumes")),
                    _("_Delete"))) {
                yield run_cleanup ({ "volume", "prune", "--all", "--force" }, _("Unused volumes deleted"));
            }
        }

        private async void prune_build_cache () {
            if (yield confirm (
                    _("Clear the Build Cache?"),
                    _("Docker estimates %s can be freed. The next image builds will take longer.").printf (reclaimable ("Build Cache")),
                    _("_Clear"))) {
                yield run_cleanup ({ "builder", "prune", "--all", "--force" }, _("Build cache cleared"));
            }
        }

        private Gtk.Widget build_containers_page () {
            var buckets = new HashTable<string, Bucket> (str_hash, str_equal);
            for (uint i = 0; i < data.containers.length; i++) {
                var c = data.containers[i];
                if (!matches ({ c.name, c.image, c.project, c.service })) {
                    continue;
                }
                var bucket = c.project != ""
                    ? project_bucket (buckets, c.project)
                    : get_bucket (buckets, "other", _("Not Part of a Compose Project"), GroupOrder.OTHER);

                var subtitle = "%s · %s".printf (c.status, c.image);
                var row = resource_row (c.name, subtitle, c.size);
                var dot = new Gtk.Image.from_icon_name ("media-record-symbolic") { tooltip_text = c.state };
                Utils.set_state_class (dot, Utils.container_state_class (c.state));
                row.add_prefix (dot);
                if (is_stopped (c)) {
                    var remove = trash_button (_("Remove Container"));
                    remove.clicked.connect (() => remove_container.begin (c));
                    row.add_suffix (remove);
                }

                bucket.add (row, c.size);
            }

            var summary = summary_group ("Containers", _("Container sizes only count the data each container wrote; its image is counted under Images."));
            int stopped = 0;
            for (uint i = 0; i < data.containers.length; i++) {
                if (is_stopped (data.containers[i])) {
                    stopped++;
                }
            }
            if (stopped > 0) {
                var prune = cleanup_button (_("Remove _Stopped…"));
                prune.tooltip_text = ngettext ("Remove %d stopped container", "Remove %d stopped containers", stopped).printf (stopped);
                prune.clicked.connect (() => prune_containers.begin (stopped));
                summary.header_suffix = prune;
            }
            return build_page (buckets, summary, _("No Containers"), "view-grid-symbolic");
        }

        private Gtk.Widget build_images_page () {
            var buckets = new HashTable<string, Bucket> (str_hash, str_equal);
            for (uint i = 0; i < data.images.length; i++) {
                var image = data.images[i];
                if (!matches ({ image.display_name, image.id, string.joinv (" ", image.projects) })) {
                    continue;
                }

                Bucket bucket;
                if (image.projects.length == 1) {
                    bucket = project_bucket (buckets, image.projects[0]);
                } else if (image.projects.length > 1) {
                    bucket = get_bucket (buckets, "shared", _("Shared by Several Projects"), GroupOrder.SHARED);
                } else if (image.containers > 0) {
                    bucket = get_bucket (buckets, "other", _("Not Part of a Compose Project"), GroupOrder.OTHER);
                } else {
                    bucket = get_bucket (buckets, "unused", _("Unused Images"), GroupOrder.UNUSED);
                }

                string[] details = {};
                details += image.containers > 0
                    ? ngettext ("Used by %d container", "Used by %d containers", image.containers).printf (image.containers)
                    : _("Not used by any container");
                details += _("Created %s").printf (image.created);
                if (image.unique_size >= 0 && image.unique_size != image.size) {
                    details += _("%s not shared with other images").printf (Utils.format_size (image.unique_size));
                }
                if (image.projects.length > 1) {
                    string[] names = {};
                    foreach (unowned string project in image.projects) {
                        var known = projects_by_compose_name[project];
                        names += known != null ? known.name : project;
                    }
                    details += _("Projects: %s").printf (string.joinv (", ", names));
                }

                var row = resource_row (image.display_name, string.joinv (" · ", details), image.size);
                if (image.containers == 0) {
                    var remove = trash_button (_("Remove Image"));
                    remove.clicked.connect (() => remove_image.begin (image));
                    row.add_suffix (remove);
                }
                bucket.add (row, image.size);
            }

            var summary = summary_group ("Images",
                _("Images share layers, so group totals can add up to more than the total size."));
            int unused = 0;
            for (uint i = 0; i < data.images.length; i++) {
                if (data.images[i].containers == 0) {
                    unused++;
                }
            }
            if (unused > 0) {
                var prune = cleanup_button (_("Remove _Unused…"));
                prune.tooltip_text = ngettext ("Remove %d image no container uses", "Remove %d images no container uses", unused).printf (unused);
                prune.clicked.connect (() => prune_images.begin (unused));
                summary.header_suffix = prune;
            }

            var cache = data.summaries["Build Cache"];
            if (cache != null) {
                var cache_row = add_property (summary, _("Build Cache"), Utils.format_size (cache.size));
                if (cache.size > 0) {
                    var clear = trash_button (_("Clear Build Cache"));
                    clear.clicked.connect (() => prune_build_cache.begin ());
                    cache_row.add_suffix (clear);
                }
            }
            return build_page (buckets, summary, _("No Images"), "package-x-generic-symbolic");
        }

        private Gtk.Widget build_volumes_page () {
            var buckets = new HashTable<string, Bucket> (str_hash, str_equal);
            for (uint i = 0; i < data.volumes.length; i++) {
                var v = data.volumes[i];
                if (!matches ({ v.name, v.project })) {
                    continue;
                }
                var bucket = v.project != ""
                    ? project_bucket (buckets, v.project)
                    : get_bucket (buckets, "other", _("Not Part of a Compose Project"), GroupOrder.OTHER);

                var usage = v.links > 0
                    ? ngettext ("Used by %d container", "Used by %d containers", v.links).printf (v.links)
                    : _("Not used by any container");
                var row = resource_row (v.name, "%s · %s".printf (usage, v.driver), v.size);
                if (v.links == 0) {
                    var remove = trash_button (_("Delete Volume"));
                    remove.clicked.connect (() => remove_volume.begin (v));
                    row.add_suffix (remove);
                }

                bucket.add (row, v.size);
            }

            var summary = summary_group ("Local Volumes", _("Volumes hold persistent data, such as databases."));
            int unused = 0;
            for (uint i = 0; i < data.volumes.length; i++) {
                if (data.volumes[i].links == 0) {
                    unused++;
                }
            }
            if (unused > 0) {
                var prune = cleanup_button (_("Delete _Unused…"));
                prune.tooltip_text = ngettext ("Delete %d volume no container uses", "Delete %d volumes no container uses", unused).printf (unused);
                prune.clicked.connect (() => prune_volumes.begin (unused));
                summary.header_suffix = prune;
            }
            return build_page (buckets, summary, _("No Volumes"), "drive-harddisk-symbolic");
        }
    }
}
