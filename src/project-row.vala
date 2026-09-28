namespace DockStation {
    public class ProjectRow : Gtk.ListBoxRow {
        public Project project { get; construct; }

        private Gtk.Image status_icon;
        private Gtk.Label status_label;

        public ProjectRow (Project project) {
            Object (project: project);
        }

        construct {
            status_icon = new Gtk.Image.from_icon_name ("media-record-symbolic") {
                valign = Gtk.Align.CENTER,
            };

            var name_label = new Gtk.Label (null) {
                xalign = 0,
                ellipsize = Pango.EllipsizeMode.END,
            };
            project.bind_property ("name", name_label, "label", BindingFlags.SYNC_CREATE);

            status_label = new Gtk.Label (null) {
                xalign = 0,
                ellipsize = Pango.EllipsizeMode.END,
            };
            status_label.add_css_class ("caption");
            status_label.add_css_class ("dim-label");

            var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
                hexpand = true,
                valign = Gtk.Align.CENTER,
            };
            labels.append (name_label);
            labels.append (status_label);

            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
                margin_top = 6,
                margin_bottom = 6,
                margin_start = 6,
                margin_end = 6,
            };
            box.append (status_icon);
            box.append (labels);
            child = box;

            tooltip_text = project.path;
            project.status_changed.connect (update_status);
            update_status ();
        }

        private void update_status () {
            status_label.label = project.status_label;
            Utils.set_state_class (status_icon, project.state.to_css_class ());
        }
    }
}
