namespace DockStation {
    public enum EditorFileKind {
        COMPOSE,
        DOCKERFILE,
    }

    /* A file listed in the Configuration tab, relative to the project folder. */
    public class EditorFile : Object {
        public string path { get; construct; }
        public EditorFileKind kind { get; construct; }

        public EditorFile (string path, EditorFileKind kind) {
            Object (path: path, kind: kind);
        }

        public string section_title {
            owned get { return kind == EditorFileKind.COMPOSE ? _("Compose") : _("Dockerfiles"); }
        }
    }

    /* Keeps the previous line's indentation, adding a level after lines that open a block ("key:"). */
    public class YamlIndenter : Object, GtkSource.Indenter {
        public bool is_trigger (GtkSource.View view, Gtk.TextIter location, Gdk.ModifierType state, uint keyval) {
            if ((state & (Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.CONTROL_MASK)) != 0) {
                return false;
            }
            return keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter;
        }

        /* Called with `iter` at the start of the new line. */
        public void indent (GtkSource.View view, ref Gtk.TextIter iter) {
            var previous = iter;
            if (!previous.backward_line ()) {
                return;
            }
            var previous_end = previous;
            if (!previous_end.ends_line ()) {
                previous_end.forward_to_line_end ();
            }
            var line = previous.get_slice (previous_end);

            var indent = new StringBuilder ();
            for (int i = 0; i < line.length && (line[i] == ' ' || line[i] == '\t'); i++) {
                indent.append_c (line[i]);
            }
            if (opens_block (line)) {
                var width = view.indent_width > 0 ? view.indent_width : (int) view.tab_width;
                indent.append (string.nfill (width, ' '));
            }

            // Replace the whitespace that followed the cursor, if any.
            var buffer = view.buffer;
            var whitespace_end = iter;
            while (!whitespace_end.ends_line () && (whitespace_end.get_char () == ' ' || whitespace_end.get_char () == '\t')) {
                whitespace_end.forward_char ();
            }
            buffer.delete (ref iter, ref whitespace_end);
            buffer.insert (ref iter, indent.str, -1);
        }

        /* "key:" or a block scalar ("key: |", "key: >-"), ignoring trailing comments. */
        private static bool opens_block (string line) {
            var text = line.strip ();
            if (text.has_prefix ("#")) {
                return false;
            }
            var comment = text.index_of (" #");
            if (comment >= 0) {
                text = text.substring (0, comment).strip ();
            }
            return text.has_suffix (":") || Regex.match_simple ("""(^|:\s)[|>][-+]?$""", text);
        }
    }

    /* The Configuration tab: edits the project's Compose files, .env and Dockerfiles. */
    public class EditorPage : Adw.Bin {
        public Project project { get; construct; }

        public signal void toast (string message);
        /* The files on disk may define different services now. */
        public signal void configuration_changed ();

        /* "save-file", "revert-file" and "validate"; the view inserts them as the "editor" group. */
        public SimpleActionGroup actions { get; default = new SimpleActionGroup (); }

        private Cancellable cancellable = new Cancellable ();
        private GLib.ListStore file_store;
        private Gtk.SortListModel file_list;
        private Cancellable? dockerfile_search = null;
        private Gtk.DropDown file_dropdown;
        private GtkSource.Buffer editor_buffer;
        private GtkSource.View editor_view;
        private Adw.Banner editor_banner;
        private uint current_file_index = 0;
        private string? editing_path = null;
        // Identifies the version on disk that was loaded, to detect changes made by other programs.
        private string? editing_etag = null;
        private ulong buffer_changed_handler;
        private ulong file_selected_handler;
        private bool dirty = false;
        private bool saving = false;
        // Bumped on every edit, so a save only clears `dirty` if nothing was typed meanwhile.
        private uint edit_serial = 0;

        public EditorPage (Project project) {
            Object (project: project);
        }

        public bool has_unsaved_changes {
            get { return dirty; }
        }

        public string editing_file_name {
            owned get { return editing_path != null ? File.new_for_path (project.path).get_relative_path (File.new_for_path (editing_path)) ?? Path.get_basename (editing_path) : ""; }
        }

        construct {
            add_action ("save-file", () => save_file.begin ());
            add_action ("revert-file", () => load_file_at (current_file_index));
            add_action ("validate", () => validate.begin (false));
            child = build_ui ();
        }

        private delegate void ActionFunc ();

        private void add_action (string name, owned ActionFunc func) {
            var action = new SimpleAction (name, null);
            action.activate.connect (() => func ());
            actions.add_action (action);
        }

        private void set_action_enabled (string name, bool enabled) {
            ((SimpleAction) actions.lookup_action (name)).set_enabled (enabled);
        }

        /* Must be called before the page is discarded, to stop background work. */
        public void shutdown () {
            cancellable.cancel ();
            if (dockerfile_search != null) {
                dockerfile_search.cancel ();
            }
            Adw.StyleManager.get_default ().notify["dark"].disconnect (update_editor_scheme);
        }

        /* Forgets the unsaved changes, for files that are gone or intentionally left as they are. */
        public void discard_changes () {
            set_dirty (false);
        }

        private Gtk.Widget build_ui () {
            // The store is kept grouped by kind; the section sorter only marks where sections start.
            file_store = new GLib.ListStore (typeof (EditorFile));
            file_list = new Gtk.SortListModel (file_store, null) {
                section_sorter = new Gtk.CustomSorter ((a, b) => {
                    return (int) ((EditorFile) a).kind - (int) ((EditorFile) b).kind;
                }),
            };

            var item_factory = new Gtk.SignalListItemFactory ();
            item_factory.setup.connect ((obj) => {
                ((Gtk.ListItem) obj).child = new Gtk.Label (null) {
                    xalign = 0,
                    ellipsize = Pango.EllipsizeMode.MIDDLE,
                    max_width_chars = 36,
                };
            });
            item_factory.bind.connect ((obj) => {
                var item = (Gtk.ListItem) obj;
                var label = (Gtk.Label) item.child;
                label.label = ((EditorFile) item.item).path;
                label.tooltip_text = label.label;
            });

            var header_factory = new Gtk.SignalListItemFactory ();
            header_factory.setup.connect ((obj) => {
                var label = new Gtk.Label (null) { xalign = 0 };
                label.add_css_class ("heading");
                ((Gtk.ListHeader) obj).child = label;
            });
            header_factory.bind.connect ((obj) => {
                var header = (Gtk.ListHeader) obj;
                ((Gtk.Label) header.child).label = ((EditorFile) header.item).section_title;
            });

            file_dropdown = new Gtk.DropDown (file_list, null) {
                factory = item_factory,
                header_factory = header_factory,
                tooltip_text = _("File"),
            };
            file_selected_handler = file_dropdown.notify["selected"].connect (on_file_selected);

            var validate_button = new Gtk.Button.with_label (_("Validate")) {
                action_name = "editor.validate",
                tooltip_text = _("Check the Compose Configuration"),
            };
            var revert_button = new Gtk.Button.from_icon_name ("edit-undo-symbolic") {
                action_name = "editor.revert-file",
                tooltip_text = _("Discard Changes"),
            };
            var save_button = new Gtk.Button.with_label (_("Save")) {
                action_name = "editor.save-file",
                tooltip_text = _("Save (Ctrl+S)"),
            };
            save_button.add_css_class ("suggested-action");

            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            bar.add_css_class ("toolbar");
            bar.append (file_dropdown);
            bar.append (new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { hexpand = true });
            bar.append (validate_button);
            bar.append (revert_button);
            bar.append (save_button);

            // Compose's messages are plain text, not markup.
            editor_banner = new Adw.Banner ("") { use_markup = false };

            editor_buffer = new GtkSource.Buffer (null);
            buffer_changed_handler = editor_buffer.changed.connect (() => {
                edit_serial++;
                set_dirty (true);
            });

            update_editor_scheme ();
            Adw.StyleManager.get_default ().notify["dark"].connect (update_editor_scheme);

            editor_view = new GtkSource.View.with_buffer (editor_buffer) {
                monospace = true,
                top_margin = 12,
                bottom_margin = 12,
                left_margin = 6,
                right_margin = 12,
                show_line_numbers = true,
                highlight_current_line = true,
                auto_indent = true,
                indent_on_tab = true,
                smart_backspace = true,
                // YAML forbids tabs.
                insert_spaces_instead_of_tabs = true,
            };
            editor_buffer.highlight_matching_brackets = true;
            // Make tabs visible: they break YAML and are easy to miss.
            editor_view.space_drawer.set_types_for_locations (GtkSource.SpaceLocationFlags.ALL,
                                                              GtkSource.SpaceTypeFlags.TAB);
            editor_view.space_drawer.enable_matrix = true;

            var toolbar = new Adw.ToolbarView () {
                content = new Gtk.ScrolledWindow () { child = editor_view, vexpand = true },
                top_bar_style = Adw.ToolbarStyle.RAISED_BORDER,
            };
            toolbar.add_top_bar (bar);
            toolbar.add_top_bar (editor_banner);

            set_dirty (false);
            return toolbar;
        }

        private EditorFile file_at (uint position) {
            return (EditorFile) file_list.get_item (position);
        }

        private uint position_of (string? path) {
            for (uint i = 0; path != null && i < file_list.get_n_items (); i++) {
                if (file_at (i).path == path) {
                    return i;
                }
            }
            return Gtk.INVALID_LIST_POSITION;
        }

        public void reload_files () {
            Object[] files = {};
            foreach (unowned string path in project.editable_files ()) {
                files += new EditorFile (path, EditorFileKind.COMPOSE);
            }
            Utils.without_handler (file_dropdown, file_selected_handler, () => {
                file_store.splice (0, file_store.get_n_items (), files);
                file_dropdown.selected = 0;
            });
            load_file_at (0);
            rescan_dockerfiles.begin ();
        }

        /* Searches the project for Dockerfiles and lists them in their own section. */
        public async void rescan_dockerfiles () {
            if (dockerfile_search != null) {
                dockerfile_search.cancel ();
            }
            var search = new Cancellable ();
            dockerfile_search = search;

            var dockerfiles = yield project.find_dockerfiles (search);
            if (search.is_cancelled ()) {
                return;
            }

            uint first = 0;
            while (first < file_store.get_n_items ()
                   && ((EditorFile) file_store.get_item (first)).kind == EditorFileKind.COMPOSE) {
                first++;
            }

            // Keep a Dockerfile that is open in the editor, even if it was moved or deleted.
            var editing = editing_file_name;
            string[] paths = dockerfiles;
            uint editing_position = position_of (editing);
            if (editing_position != Gtk.INVALID_LIST_POSITION
                && file_at (editing_position).kind == EditorFileKind.DOCKERFILE
                && !(editing in paths)) {
                paths += editing;
            }

            string[] current = {};
            for (uint i = first; i < file_store.get_n_items (); i++) {
                current += ((EditorFile) file_store.get_item (i)).path;
            }
            if (string.joinv ("\n", current) == string.joinv ("\n", paths)) {
                return;
            }

            Object[] items = {};
            foreach (unowned string path in paths) {
                items += new EditorFile (path, EditorFileKind.DOCKERFILE);
            }
            Utils.without_handler (file_dropdown, file_selected_handler, () => {
                file_store.splice (first, file_store.get_n_items () - first, items);
                var position = position_of (editing);
                if (position != Gtk.INVALID_LIST_POSITION) {
                    current_file_index = position;
                    file_dropdown.selected = position;
                }
            });
        }

        private void set_dirty (bool value) {
            dirty = value;
            set_action_enabled ("save-file", value);
            set_action_enabled ("revert-file", value);
        }

        private void load_file_at (uint index) {
            current_file_index = index;
            var file = file_at (index);
            editing_path = Path.build_filename (project.path, file.path);
            configure_editor_for (file);

            uint8[] contents = {};
            editing_etag = null;
            try {
                File.new_for_path (editing_path).load_contents (null, out contents, out editing_etag);
            } catch (IOError.NOT_FOUND e) {
                // Not created yet (e.g. .env): saving creates it.
            } catch (Error e) {
                toast (e.message);
            }

            Utils.without_handler (editor_buffer, buffer_changed_handler, () => {
                editor_buffer.begin_irreversible_action ();
                editor_buffer.text = contents.length > 0 ? (string) contents : "";
                editor_buffer.end_irreversible_action ();
            });

            Gtk.TextIter start;
            editor_buffer.get_start_iter (out start);
            editor_buffer.place_cursor (start);

            editor_banner.revealed = false;
            set_dirty (false);
        }

        /* Highlighting and indentation rules depend on the kind of file. */
        private void configure_editor_for (EditorFile file) {
            string language_id;
            if (file.kind == EditorFileKind.DOCKERFILE) {
                language_id = "docker";
            } else if (Path.get_basename (file.path) == ".env") {
                language_id = "sh";
            } else {
                language_id = "yaml";
            }
            editor_buffer.language = GtkSource.LanguageManager.get_default ().get_language (language_id);

            bool yaml = language_id == "yaml";
            editor_view.tab_width = yaml ? 2 : 4;
            editor_view.indenter = yaml ? new YamlIndenter () : null;
        }

        private void update_editor_scheme () {
            var scheme_id = Adw.StyleManager.get_default ().dark ? "Adwaita-dark" : "Adwaita";
            editor_buffer.style_scheme = GtkSource.StyleSchemeManager.get_default ().get_scheme (scheme_id);
        }

        private void on_file_selected () {
            if (file_dropdown.selected == current_file_index) {
                return;
            }
            if (!dirty) {
                load_file_at (file_dropdown.selected);
                return;
            }
            var target = file_dropdown.selected;
            ask_save_before_switch.begin (target);
        }

        private async void ask_save_before_switch (uint target) {
            if (!(yield settle_unsaved_changes ())) {
                file_dropdown.selected = current_file_index;
                return;
            }
            load_file_at (target);
        }

        /*
         * Asks whether to save or discard the editor's changes. Returns false if the
         * user cancelled or the file could not be saved; the changes are then kept.
         */
        public async bool settle_unsaved_changes () {
            var dialog = new Adw.AlertDialog (
                _("Save Changes?"),
                _("“%s” has unsaved changes.").printf (editing_file_name)
            );
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("discard", _("_Discard"));
            dialog.add_response ("save", _("_Save"));
            dialog.set_response_appearance ("discard", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_response_appearance ("save", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "save";
            dialog.close_response = "cancel";

            var response = yield dialog.choose (this, null);
            if (response == "save") {
                return yield save_file ();
            }
            if (response == "discard") {
                load_file_at (current_file_index);
                return true;
            }
            return false;
        }

        /* Returns true if the editor holds no unsaved changes afterwards. */
        public async bool save_file () {
            if (editing_path == null || !dirty) {
                return !dirty;
            }
            if (saving) {
                return false;
            }
            saving = true;
            var saved = yield write_editor_file ();
            saving = false;
            return saved;
        }

        private async bool write_editor_file () {
            var path = editing_path;
            var name = editing_file_name;
            var kind = file_at (current_file_index).kind;
            var serial = edit_serial;
            Gtk.TextIter start, end;
            editor_buffer.get_bounds (out start, out end);
            var contents = new Bytes (editor_buffer.get_text (start, end, true).data);
            var etag = editing_etag;

            while (true) {
                try {
                    string? new_etag;
                    // replace_contents keeps the permissions of an existing file (e.g. a 0600 .env).
                    // With an etag it fails instead of overwriting changes made by another program.
                    yield File.new_for_path (path).replace_contents_bytes_async (
                        contents, etag, false, FileCreateFlags.NONE, null, out new_etag);
                    if (editing_path == path) {
                        editing_etag = new_etag;
                    }
                    break;
                } catch (IOError.WRONG_ETAG e) {
                    var response = yield ask_overwrite_changed_file (name);
                    if (response == "overwrite") {
                        etag = null;
                        continue;
                    }
                    if (response == "reload" && editing_path == path) {
                        load_file_at (current_file_index);
                    }
                    return !dirty;
                } catch (Error e) {
                    toast (_("Could not save: %s").printf (e.message));
                    return false;
                }
            }

            // Keep the file marked as modified if it was edited while saving.
            if (editing_path == path && edit_serial == serial) {
                set_dirty (false);
            }
            toast (_("Saved “%s”").printf (name));

            // Only compose files and .env affect `docker compose config`.
            if (kind == EditorFileKind.COMPOSE) {
                validate.begin (true);
            }
            return !dirty;
        }

        private async string ask_overwrite_changed_file (string name) {
            var dialog = new Adw.AlertDialog (
                _("File Changed on Disk"),
                _("“%s” was modified by another program after it was opened. Overwrite it with your version, or reload it and discard your changes?").printf (name)
            );
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("reload", _("_Reload"));
            dialog.add_response ("overwrite", _("_Overwrite"));
            dialog.set_response_appearance ("reload", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_response_appearance ("overwrite", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            return yield dialog.choose (this, null);
        }

        private async void validate (bool after_save) {
            var overlay = new ComposeOverlay (project.compose_files ());
            try {
                // Check the text in the editor, not the file on disk: Compose gets a copy of it instead.
                if (dirty && file_at (current_file_index).kind == EditorFileKind.COMPOSE) {
                    overlay_editor_text (overlay);
                }

                var result = yield Docker.run (project.path, overlay.compose_args ({ "config", "--quiet" }), cancellable);
                if (result.success) {
                    editor_banner.revealed = false;
                    if (!after_save) {
                        toast (_("The configuration is valid"));
                    }
                    // The services list reflects the files on disk.
                    if (!overlay.has_copies) {
                        configuration_changed ();
                    }
                } else {
                    editor_banner.title = overlay.restore_paths (result.stderr_text.strip ());
                    editor_banner.revealed = true;
                }
            } catch (IOError.CANCELLED e) {
            } catch (Error e) {
                toast (e.message);
            } finally {
                overlay.remove ();
            }
        }

        /* Does nothing when Compose does not load the edited file at all. */
        private void overlay_editor_text (ComposeOverlay overlay) throws Error {
            Gtk.TextIter start, end;
            editor_buffer.get_bounds (out start, out end);
            var text = editor_buffer.get_text (start, end, true);
            if (Path.get_basename (editing_path) == ".env") {
                overlay.replace_env (editing_path, text);
            } else if (overlay.loads (editing_path)) {
                overlay.replace_file (editing_path, text);
            }
        }
    }
}
