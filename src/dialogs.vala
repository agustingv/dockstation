namespace DockStation.Dialogs {
    /* Asks before doing something, with Cancel as the default. Returns true if the user went ahead. */
    public async bool confirm (Gtk.Widget parent, string heading, string body, string action_label,
                               Adw.ResponseAppearance appearance = Adw.ResponseAppearance.DESTRUCTIVE,
                               Gtk.Widget? extra_child = null) {
        var dialog = new Adw.AlertDialog (heading, body) { extra_child = extra_child };
        dialog.add_response ("cancel", _("_Cancel"));
        dialog.add_response ("confirm", action_label);
        dialog.set_response_appearance ("confirm", appearance);
        dialog.default_response = "cancel";
        dialog.close_response = "cancel";
        return (yield dialog.choose (parent, null)) == "confirm";
    }

    /* The header of a dialog that asks for something: Cancel closes it, `action` does it. */
    public Adw.HeaderBar action_header (Adw.Dialog dialog, Gtk.Button action) {
        var cancel_button = new Gtk.Button.with_mnemonic (_("_Cancel"));
        cancel_button.clicked.connect (() => dialog.close ());
        action.add_css_class ("suggested-action");

        var header = new Adw.HeaderBar () {
            show_start_title_buttons = false,
            show_end_title_buttons = false,
        };
        header.pack_start (cancel_button);
        header.pack_end (action);
        return header;
    }

    public void show_error (Gtk.Widget parent, string heading, string message) {
        var dialog = new Adw.AlertDialog (heading, message);
        dialog.add_response ("close", _("_Close"));
        dialog.present (parent);
    }
}
