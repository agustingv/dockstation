namespace DockStation.Widgets {
    private const string[] STATE_CLASSES = { "success", "warning", "error", "dim-label" };

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

    public string project_state_class (ProjectState state) {
        switch (state) {
            case ProjectState.RUNNING:
                return "success";
            case ProjectState.PARTIAL:
                return "warning";
            default:
                return "dim-label";
        }
    }

    public string container_state_class (ContainerState state) {
        switch (state) {
            case ContainerState.RUNNING:
                return "success";
            case ContainerState.RESTARTING:
            case ContainerState.PAUSED:
            case ContainerState.REMOVING:
                return "warning";
            case ContainerState.DEAD:
                return "error";
            default:
                return "dim-label";
        }
    }
}
