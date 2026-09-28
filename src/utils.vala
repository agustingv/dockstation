namespace DockStation.Utils {
    private const string[] STATE_CLASSES = { "success", "warning", "error", "dim-label" };

    /* Applies exactly one of the libadwaita state style classes to a widget. */
    public void set_state_class (Gtk.Widget widget, string css_class) {
        foreach (unowned string c in STATE_CLASSES) {
            widget.remove_css_class (c);
        }
        widget.add_css_class (css_class);
    }

    public string container_state_class (string state) {
        switch (state) {
            case "running":
                return "success";
            case "restarting":
            case "paused":
            case "removing":
                return "warning";
            case "dead":
                return "error";
            default:
                return "dim-label";
        }
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

    public string random_secret (int length) {
        const string ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
        var bytes = new uint8[length];
        var urandom = FileStream.open ("/dev/urandom", "rb");
        if (urandom == null || urandom.read (bytes) != length) {
            for (int i = 0; i < length; i++) {
                bytes[i] = (uint8) Random.int_range (0, 256);
            }
        }
        var builder = new StringBuilder ();
        foreach (var b in bytes) {
            builder.append_c (ALPHABET[b % ALPHABET.length]);
        }
        return builder.str;
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
