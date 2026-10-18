namespace Pipoca.Background {
    /* Command line for starting at login without a window */
    private const string BACKGROUND_OPTION = "--background";

    public bool is_sandboxed () {
        return FileUtils.test ("/.flatpak-info", FileTest.EXISTS);
    }

    /**
     * Asks to run in the background and, with @autostart, to start at
     * login. Returns whether running in the background is allowed.
     *
     * Sandboxed, this goes through the Background portal, which may ask the
     * user. Otherwise the portal can't tell which app is asking, so the
     * autostart entry is written directly.
     */
    public async bool request (string reason, bool autostart) throws Error {
        if (!is_sandboxed ()) {
            set_autostart_file (autostart);
            return true;
        }
        var options = new VariantBuilder (new VariantType ("a{sv}"));
        options.add ("{sv}", "reason", new Variant.string (reason));
        options.add ("{sv}", "autostart", new Variant.boolean (autostart));
        options.add ("{sv}", "commandline", new Variant.strv ({ "pipoca", BACKGROUND_OPTION }));
        options.add ("{sv}", "dbus-activatable", new Variant.boolean (false));
        var results = yield call_portal_request ("org.freedesktop.portal.Background", "RequestBackground", options);
        bool allowed;
        return results.lookup ("background", "b", out allowed) && allowed;
    }

    /* Shown by the desktop next to the app while it runs in the background */
    public async void set_status (string message) {
        if (!is_sandboxed ()) {
            return;
        }
        try {
            var bus = yield GLib.Bus.get (BusType.SESSION);
            var options = new VariantBuilder (new VariantType ("a{sv}"));
            options.add ("{sv}", "message", new Variant.string (message));
            yield bus.call ("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                            "org.freedesktop.portal.Background", "SetStatus",
                            new Variant ("(a{sv})", options), null, DBusCallFlags.NONE, -1);
        } catch (Error e) {
            debug ("Can't set background status: %s", e.message);
        }
    }

    /*
     * Calls a portal method taking (parent_window, options) that answers
     * through a Request object's Response signal, and returns the results.
     */
    private async Variant call_portal_request (string iface, string method, VariantBuilder options) throws Error {
        var bus = yield GLib.Bus.get (BusType.SESSION);
        var token = "pipoca%u".printf (Random.next_int ());
        options.add ("{sv}", "handle_token", new Variant.string (token));
        var sender = bus.unique_name.substring (1).replace (".", "_");
        var handle = "/org/freedesktop/portal/desktop/request/%s/%s".printf (sender, token);

        uint32 response = 2;
        Variant? results = null;
        var received = false;
        var waiting = false;
        SourceFunc callback = call_portal_request.callback;
        // Subscribe before calling so the response can't be missed
        var id = bus.signal_subscribe ("org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response",
                                       handle, null, DBusSignalFlags.NO_MATCH_RULE, (conn, s, path, i, name, parameters) => {
            parameters.get ("(u@a{sv})", out response, out results);
            received = true;
            if (waiting) {
                Idle.add ((owned) callback);
            }
        });
        try {
            yield bus.call ("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", iface, method,
                            new Variant ("(sa{sv})", "", options), null, DBusCallFlags.NONE, -1);
            if (!received) {
                waiting = true;
                yield;
            }
        } finally {
            bus.signal_unsubscribe (id);
        }
        if (response == 1) {
            throw new IOError.CANCELLED ("Cancelled");
        }
        if (response != 0 || results == null) {
            throw new IOError.FAILED (_("The request was denied"));
        }
        return results;
    }

    private void set_autostart_file (bool enabled) throws Error {
        var dir = Path.build_filename (Environment.get_user_config_dir (), "autostart");
        var path = Path.build_filename (dir, Config.APPLICATION_ID + ".desktop");
        if (!enabled) {
            FileUtils.remove (path);
            return;
        }
        var exe = FileUtils.read_link ("/proc/self/exe");
        var entry = new KeyFile ();
        entry.set_string ("Desktop Entry", "Type", "Application");
        entry.set_string ("Desktop Entry", "Name", _("Pipoca"));
        entry.set_string ("Desktop Entry", "Exec", "%s %s".printf (Shell.quote (exe), BACKGROUND_OPTION));
        entry.set_string ("Desktop Entry", "Icon", Config.APPLICATION_ID);
        entry.set_boolean ("Desktop Entry", "X-GNOME-Autostart-enabled", true);
        DirUtils.create_with_parents (dir, 0755);
        entry.save_to_file (path);
    }
}
