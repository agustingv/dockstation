namespace DockStation {
    /*
     * A tray icon, for desktops that show StatusNotifierItems: KDE, and GNOME with the
     * AppIndicator extension (enabled by default on Ubuntu). GTK 4 has no tray API, so this
     * speaks the two D-Bus protocols directly:
     *   org.kde.StatusNotifierItem  the icon     https://www.freedesktop.org/wiki/Specifications/StatusNotifierItem/
     *   com.canonical.dbusmenu      its menu     https://github.com/AyatanaIndicators/libdbusmenu
     */

    public struct TrayPixmap {
        int width;
        int height;
        uint8[] data;
    }

    public struct TrayToolTip {
        string icon_name;
        TrayPixmap[] icon_pixmap;
        string title;
        string description;
    }

    [DBus (name = "org.kde.StatusNotifierItem")]
    public class TrayItem : Object {
        public string category { owned get { return "ApplicationStatus"; } }
        public string id { owned get { return Config.APP_ID; } }
        public string title { owned get { return "DockStation"; } }
        // "Passive" asks the desktop to hide the icon.
        public string status { owned get { return active ? "Active" : "Passive"; } }
        public string icon_name { owned get { return Config.APP_ID; } }
        public string overlay_icon_name { owned get { return ""; } }
        public string attention_icon_name { owned get { return ""; } }
        public bool item_is_menu { get { return false; } }
        public ObjectPath menu { owned get { return new ObjectPath (TrayIcon.MENU_PATH); } }

        private string description = "";
        private bool active = false;

        public TrayToolTip tool_tip {
            owned get {
                return TrayToolTip () {
                    icon_name = Config.APP_ID,
                    icon_pixmap = {},
                    title = "DockStation",
                    description = description,
                };
            }
        }

        public signal void new_icon ();
        public signal void new_tool_tip ();
        public signal void new_status (string status);

        [DBus (visible = false)]
        public signal void activated ();

        [DBus (visible = false)]
        public void set_active (bool value) {
            if (value != active) {
                active = value;
                new_status (status);
            }
        }

        [DBus (visible = false)]
        public void set_description (string text) {
            if (text != description) {
                description = text;
                new_tool_tip ();
            }
        }

        public void activate (int x, int y) throws DBusError, IOError {
            activated ();
        }

        public void secondary_activate (int x, int y) throws DBusError, IOError {
            activated ();
        }

        // The menu is exported separately; desktops show it themselves.
        public void context_menu (int x, int y) throws DBusError, IOError {
        }

        public void scroll (int delta, string orientation) throws DBusError, IOError {
        }
    }

    /* An entry of the tray menu. Separators have no label; `action` tells the owner what to do. */
    public class TrayMenuItem {
        public int id;
        public string label;
        public bool enabled = true;
        public bool is_separator = false;
        public string action = "";
        public Object? target = null;
        public TrayMenuItem[] children = {};

        public TrayMenuItem (string label, string action = "", Object? target = null) {
            this.label = label;
            this.action = action;
            this.target = target;
        }

        public TrayMenuItem.separator () {
            this.label = "";
            this.is_separator = true;
        }

        /* Labels use "_" for mnemonics, so a literal one is doubled. */
        public static string escape (string text) {
            return text.replace ("_", "__");
        }
    }

    public struct TrayMenuLayout {
        int id;
        HashTable<string, Variant> properties;
        Variant[] children;
    }

    public struct TrayMenuItemProperties {
        int id;
        HashTable<string, Variant> properties;
    }

    public struct TrayMenuEvent {
        int id;
        string event_id;
        Variant data;
        uint timestamp;
    }

    [DBus (name = "com.canonical.dbusmenu")]
    public class TrayMenu : Object {
        public uint version { get { return 3; } }
        public string text_direction { owned get { return "ltr"; } }
        public string status { owned get { return "normal"; } }
        public string[] icon_theme_path { owned get { return {}; } }

        private TrayMenuItem root = new TrayMenuItem ("");
        private uint revision = 0;
        private string signature = "";
        private HashTable<int, TrayMenuItem> by_id = new HashTable<int, TrayMenuItem> (direct_hash, direct_equal);

        public signal void layout_updated (uint revision, int parent);

        [DBus (visible = false)]
        public signal void item_activated (TrayMenuItem item);

        /* Replaces the menu; clients are only told when something visible changed. */
        [DBus (visible = false)]
        public void set_items (TrayMenuItem[] items) {
            root.children = items;
            by_id.remove_all ();
            var description = new StringBuilder ();
            int next_id = 1;
            number (root, ref next_id, description);
            by_id[0] = root;
            if (description.str != signature) {
                signature = description.str;
                revision++;
                layout_updated (revision, 0);
            }
        }

        private void number (TrayMenuItem item, ref int next_id, StringBuilder description) {
            foreach (var child in item.children) {
                child.id = next_id++;
                by_id[child.id] = child;
                description.append_printf ("%d|%s|%s|%s;", child.id, child.label, child.enabled.to_string (), child.is_separator.to_string ());
                if (child.children.length > 0) {
                    description.append ("[");
                    number (child, ref next_id, description);
                    description.append ("]");
                }
            }
        }

        private static HashTable<string, Variant> item_properties (TrayMenuItem item) {
            var properties = new HashTable<string, Variant> (str_hash, str_equal);
            if (item.is_separator) {
                properties["type"] = "separator";
                return properties;
            }
            if (item.id != 0) {
                properties["label"] = item.label;
                properties["enabled"] = item.enabled;
            }
            if (item.children.length > 0) {
                properties["children-display"] = "submenu";
            }
            return properties;
        }

        private static Variant properties_variant (TrayMenuItem item) {
            var builder = new VariantBuilder (new VariantType ("a{sv}"));
            item_properties (item).foreach ((key, value) => builder.add ("{sv}", key, value));
            return builder.end ();
        }

        private static Variant layout_variant (TrayMenuItem item, int depth) {
            var children = new VariantBuilder (new VariantType ("av"));
            if (depth != 0) {
                foreach (var child in item.children) {
                    children.add ("v", layout_variant (child, depth - 1));
                }
            }
            return new Variant ("(i@a{sv}@av)", item.id, properties_variant (item), children.end ());
        }

        public void get_layout (int parent_id, int recursion_depth, string[] property_names,
                                out uint revision, out TrayMenuLayout layout) throws DBusError, IOError {
            var item = by_id[parent_id] ?? root;
            Variant[] children = {};
            if (recursion_depth != 0) {
                foreach (var child in item.children) {
                    children += layout_variant (child, recursion_depth - 1);
                }
            }
            revision = this.revision;
            layout = TrayMenuLayout () {
                id = item.id,
                properties = item_properties (item),
                children = children,
            };
        }

        public void get_group_properties (int[] ids, string[] property_names,
                                          out TrayMenuItemProperties[] properties) throws DBusError, IOError {
            TrayMenuItemProperties[] result = {};
            foreach (var id in ids) {
                var item = by_id[id];
                if (item != null) {
                    result += TrayMenuItemProperties () { id = id, properties = item_properties (item) };
                }
            }
            properties = result;
        }

        [DBus (name = "GetProperty")]
        public Variant get_item_property (int id, string name) throws DBusError, IOError {
            var item = by_id[id];
            var value = item != null ? item_properties (item)[name] : null;
            if (value == null) {
                throw new DBusError.INVALID_ARGS ("No property %s on item %d", name, id);
            }
            return value;
        }

        public void event (int id, string event_id, Variant data, uint timestamp) throws DBusError, IOError {
            var item = by_id[id];
            if (item != null && event_id == "clicked" && item.enabled && !item.is_separator) {
                // Let the menu close before acting on the click.
                Idle.add (() => {
                    item_activated (item);
                    return Source.REMOVE;
                });
            }
        }

        public void event_group (TrayMenuEvent[] events, out int[] id_errors) throws DBusError, IOError {
            int[] errors = {};
            foreach (var e in events) {
                if (!by_id.contains (e.id)) {
                    errors += e.id;
                    continue;
                }
                event (e.id, e.event_id, e.data, e.timestamp);
            }
            id_errors = errors;
        }

        public bool about_to_show (int id) throws DBusError, IOError {
            return false;
        }

        public void about_to_show_group (int[] ids, out int[] updates_needed, out int[] id_errors) throws DBusError, IOError {
            updates_needed = {};
            id_errors = {};
        }
    }

    /* Shows the icon while the desktop's StatusNotifierWatcher is around, and re-registers when it restarts. */
    public class TrayIcon : Object {
        public const string ITEM_PATH = "/StatusNotifierItem";
        public const string MENU_PATH = "/MenuBar";
        private const string WATCHER = "org.kde.StatusNotifierWatcher";

        public TrayItem item { get; default = new TrayItem (); }
        public TrayMenu menu { get; default = new TrayMenu (); }

        private DBusConnection connection;
        private uint item_registration = 0;
        private uint menu_registration = 0;
        private uint watch_id = 0;

        public TrayIcon (DBusConnection connection) {
            this.connection = connection;
        }

        public void show () {
            item.set_active (true);
            if (watch_id != 0) {
                return;
            }
            try {
                item_registration = connection.register_object (ITEM_PATH, item);
                menu_registration = connection.register_object (MENU_PATH, menu);
            } catch (IOError e) {
                warning ("Could not export the tray icon: %s", e.message);
                unregister ();
                return;
            }
            // Register now and whenever the watcher (re)starts, such as after the shell restarts.
            watch_id = Bus.watch_name_on_connection (connection, WATCHER, BusNameWatcherFlags.NONE,
                                                     (conn, name, owner) => register_with_watcher.begin ());
        }

        /*
         * The watcher tracks the item by the app's D-Bus connection, which stays open, so the
         * item stays registered and asks to be hidden instead.
         */
        public void hide () {
            item.set_active (false);
        }

        private void unregister () {
            if (watch_id != 0) {
                Bus.unwatch_name (watch_id);
                watch_id = 0;
            }
            if (item_registration != 0) {
                connection.unregister_object (item_registration);
                item_registration = 0;
            }
            if (menu_registration != 0) {
                connection.unregister_object (menu_registration);
                menu_registration = 0;
            }
        }

        private async void register_with_watcher () {
            try {
                // An object path instead of a bus name: the sender's own name is used, so the
                // Flatpak needs no permission to own a well-known name.
                yield connection.call (WATCHER, "/StatusNotifierWatcher", WATCHER, "RegisterStatusNotifierItem",
                                       new Variant ("(s)", ITEM_PATH), null, DBusCallFlags.NONE, -1, null);
            } catch (Error e) {
                warning ("Could not register the tray icon: %s", e.message);
            }
        }
    }
}
