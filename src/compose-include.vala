namespace DockStation {
    /* Where the top-level `include:` list of a compose file is, read line by line. */
    public class ComposeInclude {
        // The `include:` line, or -1 if the file has no list.
        public int key_line = -1;
        // A flow list such as `include: [a.yaml]`, which cannot be edited by lines.
        public bool is_flow_list = false;
        public int[] item_lines = {};
        public string[] paths = {};
        // The line after the last one of the list.
        public int end_line = 0;
        // The indentation of the list's items.
        public string indent = "  ";

        public ComposeInclude (string[] lines) {
            for (int i = 0; i < lines.length && key_line < 0; i++) {
                if (lines[i].has_prefix ("include:")) {
                    key_line = i;
                }
            }
            if (key_line < 0) {
                return;
            }
            var rest = lines[key_line].substring ("include:".length).strip ();
            is_flow_list = rest != "" && !rest.has_prefix ("#");

            int[] found_lines = {};
            string[] found_paths = {};
            end_line = key_line + 1;
            for (int i = key_line + 1; i < lines.length; i++) {
                unowned string line = lines[i];
                var stripped = line.strip ();
                if (stripped == "" || stripped.has_prefix ("#")) {
                    continue;
                }
                if (!line.has_prefix (" ") && !line.has_prefix ("\t") && !line.has_prefix ("-")) {
                    break;  // The next top-level key
                }
                if (stripped.has_prefix ("-")) {
                    if (found_lines.length == 0) {
                        indent = line.substring (0, line.index_of ("-"));
                    }
                    found_lines += i;
                    found_paths += item_value (stripped);
                }
                end_line = i + 1;
            }
            item_lines = found_lines;
            paths = found_paths;
        }

        /* "- 'a.yaml' # comment" → "a.yaml" */
        private static string item_value (string item) {
            var value = item.substring (1).strip ();
            var comment = value.index_of (" #");
            if (comment >= 0) {
                value = value.substring (0, comment).strip ();
            }
            if (value.length >= 2 && (value[0] == '"' || value[0] == '\'') && value[value.length - 1] == value[0]) {
                value = value.substring (1, value.length - 2);
            }
            return value;
        }
    }
}
