namespace DockStation.Utils {
    private const string[] STATE_CLASSES = { "success", "warning", "error", "dim-label" };

    private bool? sandboxed = null;

    public bool in_flatpak () {
        if (sandboxed == null) {
            sandboxed = FileUtils.test ("/.flatpak-info", FileTest.EXISTS);
        }
        return sandboxed;
    }

    public string[] to_array (GenericArray<string> items) {
        string[] result = {};
        foreach (unowned string item in items) {
            result += item;
        }
        return result;
    }

    /* A small button with just an icon, for the end of a row. */
    public Gtk.Button flat_icon_button (string icon, string tooltip) {
        var button = new Gtk.Button.from_icon_name (icon) {
            tooltip_text = tooltip,
            valign = Gtk.Align.CENTER,
        };
        button.add_css_class ("flat");
        return button;
    }

    /* Applies exactly one of the libadwaita state style classes to a widget. */
    public void set_state_class (Gtk.Widget widget, string css_class) {
        foreach (unowned string c in STATE_CLASSES) {
            widget.remove_css_class (c);
        }
        widget.add_css_class (css_class);
    }

    public delegate void Change ();

    /* Makes a change from code that `handler`, connected to `source`, must not react to. */
    public void without_handler (Object source, ulong handler, Change change) {
        SignalHandler.block (source, handler);
        change ();
        SignalHandler.unblock (source, handler);
    }

    /* Turns a human project name into a folder / compose project name. */
    public string slugify (string text) {
        var normalized = text.normalize (-1, NormalizeMode.NFD).down ();
        var builder = new StringBuilder ();
        bool pending_dash = false;
        for (int i = 0; i < normalized.length; i++) {
            char c = normalized[i];
            if (c.isalnum ()) {
                if (pending_dash && builder.len > 0) {
                    builder.append_c ('-');
                }
                builder.append_c (c);
                pending_dash = false;
            } else if (c == ' ' || c == '-' || c == '_' || c == '.') {
                pending_dash = true;
            }
        }
        return builder.str;
    }

    public string[] split_lines (string text) {
        string[] lines = {};
        foreach (unowned string line in text.split ("\n")) {
            var stripped = line.strip ();
            if (stripped != "") {
                lines += stripped;
            }
        }
        return lines;
    }

    /* The first line of a command's message, or null if it is empty. */
    public string? first_line (string text) {
        var lines = text.strip ().split ("\n");
        return lines.length > 0 ? lines[0].strip () : null;
    }

    /* Removes terminal control sequences; Compose sends them even with --no-color, such as ESC[2K before log lines. */
    public string strip_terminal_codes (string text) {
        if (!text.contains ("\x1b")) {
            return text;
        }
        try {
            return /\x1b\[[0-9;?]*[ -\/]*[@-~]/.replace (text, -1, 0, "");
        } catch (RegexError e) {
            return text;
        }
    }

    private Regex? port_regex = null;

    private Regex get_port_regex () {
        if (port_regex == null) {
            try {
                port_regex = new Regex ("(?:[0-9.]+|\\[[0-9a-fA-F:]*\\]):([0-9]+)->([0-9]+(?:-[0-9]+)?/[a-z]+)");
            } catch (RegexError e) {
                critical ("Invalid port regex: %s", e.message);
            }
        }
        return port_regex;
    }

    /* "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp" → "8080 → 80/tcp" */
    public string simplify_ports (string ports) {
        string[] seen = {};
        MatchInfo info;
        if (get_port_regex ().match (ports, 0, out info)) {
            try {
                do {
                    var mapping = "%s → %s".printf (info.fetch (1), info.fetch (2));
                    if (!(mapping in seen)) {
                        seen += mapping;
                    }
                } while (info.next ());
            } catch (RegexError e) {
            }
        }
        return string.joinv (", ", seen);
    }

    /* Returns the first published host port, or 0 if none. */
    public int first_host_port (string ports) {
        MatchInfo info;
        if (get_port_regex ().match (ports, 0, out info)) {
            return int.parse (info.fetch (1));
        }
        return 0;
    }

    /* Parses Docker's human sizes, which use decimal units: "0B", "57.3kB", "2.93GB". Returns -1 if unknown. */
    public int64 parse_size (string text) {
        var trimmed = text.strip ();
        int end = 0;
        while (end < trimmed.length && (trimmed[end].isdigit () || trimmed[end] == '.')) {
            end++;
        }
        if (end == 0) {
            return -1;
        }
        double value = double.parse (trimmed.substring (0, end));  // g_ascii_strtod: locale independent
        double multiplier;
        switch (trimmed.substring (end).strip ().up ()) {
            case "B": multiplier = 1; break;
            case "KB": multiplier = 1e3; break;
            case "MB": multiplier = 1e6; break;
            case "GB": multiplier = 1e9; break;
            case "TB": multiplier = 1e12; break;
            case "PB": multiplier = 1e15; break;
            default: return -1;
        }
        return (int64) (value * multiplier);
    }

    public string format_size (int64 bytes) {
        return bytes < 0 ? "–" : GLib.format_size ((uint64) bytes);
    }

    /* The project name Compose derives from a folder name. */
    public string project_name_from_folder (string folder_name) {
        var builder = new StringBuilder ();
        var lower = folder_name.down ();
        for (int i = 0; i < lower.length; i++) {
            char c = lower[i];
            if (c.isalnum () || ((c == '-' || c == '_') && builder.len > 0)) {
                builder.append_c (c);
            }
        }
        return builder.str;
    }

    public string home_relative (string path) {
        var home = Environment.get_home_dir ();
        if (path == home) {
            return "~";
        }
        if (path.has_prefix (home + "/")) {
            return "~" + path.substring (home.length);
        }
        return path;
    }

    /* Fails rather than falling back to a weak generator: these are real passwords. */
    public string random_secret (int length) throws Error {
        const string ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
        var bytes = new uint8[length];
        size_t bytes_read;
        File.new_for_path ("/dev/urandom").read ().read_all (bytes, out bytes_read);
        if (bytes_read != length) {
            throw new IOError.FAILED ("Could not read enough random data");
        }
        var builder = new StringBuilder ();
        foreach (var b in bytes) {
            builder.append_c (ALPHABET[b % ALPHABET.length]);
        }
        return builder.str;
    }

    /* Splits a line of a .env file. Returns false if it defines nothing, such as a comment. */
    public bool parse_env_line (string text, out string key, out string value) {
        key = "";
        value = "";
        var line = text.strip ();
        if (line.has_prefix ("export ")) {
            line = line.substring (7).strip ();
        }
        var equals = line.index_of ("=");
        if (line.has_prefix ("#") || equals <= 0) {
            return false;
        }
        key = line.substring (0, equals).strip ();
        value = line.substring (equals + 1).strip ();
        return true;
    }

    /* Names of the variables defined in the text of a .env file. */
    public string[] env_keys (string text) {
        string[] keys = {};
        foreach (unowned string line in text.split ("\n")) {
            string key, value;
            if (parse_env_line (line, out key, out value)) {
                keys += key;
            }
        }
        return keys;
    }

    /*
     * Writes `text` to a new hidden file next to `original` and returns its path. Being
     * in the same folder, paths relative to the original (include, extends) still work.
     * The file is private: .env files often hold secrets.
     */
    public string write_hidden_copy (string original, string text) throws Error {
        var file = File.new_for_path (Path.build_filename (
            Path.get_dirname (original),
            ".%s.dockstation-%s".printf (Path.get_basename (original), Uuid.string_random ().substring (0, 8))
        ));
        var stream = file.create (FileCreateFlags.PRIVATE);
        try {
            stream.write_all (text.data, null);
            stream.close ();
        } catch (Error e) {
            FileUtils.unlink (file.get_path ());
            throw e;
        }
        return file.get_path ();
    }

    public bool is_directory_empty (File dir) {
        try {
            var enumerator = dir.enumerate_children (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);
            return enumerator.next_file () == null;
        } catch (Error e) {
            return !dir.query_exists ();
        }
    }
}
