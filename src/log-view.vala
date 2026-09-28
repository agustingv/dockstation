namespace DockStation {
    /* Read-only, auto-scrolling monospace text area with a line limit. */
    public class LogView : Adw.Bin {
        public int max_lines { get; set; default = 5000; }

        private Gtk.ScrolledWindow scrolled;
        private Gtk.TextView view;
        private Gtk.TextBuffer buffer;
        private Gtk.TextMark end_mark;

        construct {
            buffer = new Gtk.TextBuffer (null);
            view = new Gtk.TextView.with_buffer (buffer) {
                editable = false,
                cursor_visible = false,
                monospace = true,
                wrap_mode = Gtk.WrapMode.WORD_CHAR,
                top_margin = 12,
                bottom_margin = 12,
                left_margin = 12,
                right_margin = 12,
            };
            scrolled = new Gtk.ScrolledWindow () { child = view, vexpand = true };
            child = scrolled;
            vexpand = true;

            Gtk.TextIter end;
            buffer.get_end_iter (out end);
            end_mark = buffer.create_mark (null, end, false);
        }

        public void append (string text) {
            var adj = scrolled.vadjustment;
            bool at_bottom = adj.value >= adj.upper - adj.page_size - 24;

            Gtk.TextIter end;
            buffer.get_end_iter (out end);
            buffer.insert (ref end, text, -1);

            int excess = buffer.get_line_count () - max_lines;
            if (excess > 0) {
                Gtk.TextIter start, cut;
                buffer.get_start_iter (out start);
                buffer.get_iter_at_line (out cut, excess);
                buffer.delete (ref start, ref cut);
            }

            if (at_bottom) {
                view.scroll_to_mark (end_mark, 0, false, 0, 1);
            }
        }

        public void clear () {
            buffer.text = "";
        }
    }
}
