namespace DockStation {
    /*
     * Running with the window closed, through the background portal: permission to keep
     * running, and the status GNOME shows in the Background Apps list of its quick settings.
     * GNOME only lists sandboxed apps there, so the status is only visible in the Flatpak.
     */
    public class Background : Object {
        // The portal limits the status message to 96 characters.
        private const int MAX_STATUS_LENGTH = 96;

        private Xdp.Portal portal = new Xdp.Portal ();
        private string? last_status = null;

        private static bool sandboxed () {
            return FileUtils.test ("/.flatpak-info", FileTest.EXISTS);
        }

        /* Asks to keep running in the background. Returns false if the user refused. */
        public async bool request (Gtk.Window window) {
            try {
                return yield portal.request_background (
                    Xdp.parent_new_gtk (window),
                    _("DockStation keeps showing the state of your projects when its window is closed."),
                    null, Xdp.BackgroundFlags.NONE, null);
            } catch (IOError.CANCELLED e) {
                return false;
            } catch (Error e) {
                // Apps outside a sandbox need no permission; without the portal there is nobody to ask.
                debug ("Background request failed: %s", e.message);
                return !sandboxed ();
            }
        }

        public async void set_status (string status) {
            var message = status.char_count () > MAX_STATUS_LENGTH
                ? status.substring (0, status.index_of_nth_char (MAX_STATUS_LENGTH - 1)) + "…"
                : status;
            if (message == last_status) {
                return;
            }
            last_status = message;
            try {
                yield portal.set_background_status (message, null);
            } catch (Error e) {
                debug ("Could not set the background status: %s", e.message);
            }
        }
    }
}
