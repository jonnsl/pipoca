namespace Pipoca {
    /* Preferences for syncing with Radarr or Sonarr; call setup() once */
    [GtkTemplate (ui = "/io/github/jonnsl/Pipoca/widgets/arr-preferences-group.ui")]
    public class ArrPreferencesGroup : Adw.PreferencesGroup {
        [GtkChild] private unowned Adw.SwitchRow enabled_row;
        [GtkChild] private unowned Adw.ComboRow interval_row;
        [GtkChild] private unowned Adw.SwitchRow read_only_row;
        [GtkChild] private unowned Adw.EntryRow address_row;
        [GtkChild] private unowned Adw.PasswordEntryRow api_key_row;
        [GtkChild] private unowned Adw.EntryRow username_row;
        [GtkChild] private unowned Adw.PasswordEntryRow password_row;
        [GtkChild] private unowned Adw.SwitchRow certificate_row;
        [GtkChild] private unowned Adw.ComboRow profile_row;
        [GtkChild] private unowned Adw.ComboRow folder_row;
        [GtkChild] private unowned Adw.ActionRow status_row;
        [GtkChild] private unowned Adw.Spinner spinner;
        [GtkChild] private unowned Gtk.Button sync_button;

        /* Minutes for each interval_row choice */
        private const int[] SYNC_INTERVALS = { 15, 60, 360, 1440 };

        private ArrSync sync;
        private Settings settings;
        private bool disposed;
        /* The service's quality profile ids and root folders, in the order of their rows' choices */
        private int64[] profile_ids = {};
        private string[] folders = {};

        /* For the dialog to show; it may be closed by the time a sync ends */
        public signal void toast (string message);

        public void setup (ArrSync sync) {
            this.sync = sync;
            settings = new Settings (Config.APPLICATION_ID);
            title = sync.service;
            if (sync.media_type == MediaType.MOVIE) {
                description = _("Import movies from Radarr. Unless it’s read-only, movies on your watchlist are added to Radarr too, monitored but without starting a search. Nothing is ever removed on either side.");
                read_only_row.subtitle = _("Import from Radarr without adding movies to it");
                address_row.tooltip_text = _("Radarr’s address, e.g. http://192.168.1.10:7878");
                profile_row.subtitle = folder_row.subtitle = _("For movies added to Radarr");
            } else {
                description = _("Import shows from Sonarr. Unless it’s read-only, shows you haven’t finished are added to Sonarr too, with the episodes you haven’t watched monitored but without starting a search. Nothing is ever removed on either side.");
                read_only_row.subtitle = _("Import from Sonarr without adding shows to it");
                address_row.tooltip_text = _("Sonarr’s address, e.g. http://192.168.1.10:8989");
                profile_row.subtitle = folder_row.subtitle = _("For shows added to Sonarr");
            }

            settings.bind (sync.key ("enabled"), enabled_row, "active", SettingsBindFlags.DEFAULT);
            settings.bind (sync.key ("read-only"), read_only_row, "active", SettingsBindFlags.DEFAULT);
            settings.bind (sync.key ("address"), address_row, "text", SettingsBindFlags.DEFAULT);
            settings.bind (sync.key ("username"), username_row, "text", SettingsBindFlags.DEFAULT);
            settings.bind (sync.key ("accept-any-certificate"), certificate_row, "active", SettingsBindFlags.DEFAULT);

            var minutes = settings.get_int (sync.key ("sync-interval"));
            interval_row.selected = 1;
            for (var i = 0; i < SYNC_INTERVALS.length; i++) {
                if (SYNC_INTERVALS[i] == minutes) {
                    interval_row.selected = i;
                }
            }
            interval_row.notify["selected"].connect (() => {
                settings.set_int (sync.key ("sync-interval"), SYNC_INTERVALS[interval_row.selected]);
            });
            read_only_row.notify["active"].connect (update_destination_rows);

            sync.notify["syncing"].connect (update_status);
            sync.notify["last-error"].connect (update_status);
            update_status ();
            load_secrets.begin ();
        }

        public override void dispose () {
            disposed = true;
            if (sync != null) {
                sync.notify["syncing"].disconnect (update_status);
                sync.notify["last-error"].disconnect (update_status);
            }
            dispose_template (typeof (ArrPreferencesGroup));
            base.dispose ();
        }

        private async void load_secrets () {
            try {
                api_key_row.text = (yield sync.get_secret ("api-key")) ?? "";
                password_row.text = (yield sync.get_secret ("password")) ?? "";
            } catch (Error e) {
                warning ("Can't read %s's secrets from the keyring: %s", sync.service, e.message);
            }
            if (!disposed && api_key_row.text != "" && address_row.text != "") {
                yield load_destinations ();
            }
        }

        /* Fills the quality profile and root folder rows with what the service has */
        private async void load_destinations () {
            GenericArray<ArrQualityProfile> profiles;
            string[] found_folders;
            try {
                var client = yield sync.make_client ();
                profiles = yield client.get_quality_profiles ();
                found_folders = yield client.get_root_folders ();
            } catch (Error e) {
                debug ("Can't load %s's quality profiles and root folders: %s", sync.service, e.message);
                return;
            }
            if (disposed) {
                return;
            }

            // The first one is what a sync uses when the chosen one is gone
            var names = new Gtk.StringList (null);
            profile_ids = {};
            uint selected = 0;
            foreach (var p in profiles) {
                if (p.id == settings.get_int64 (sync.key ("quality-profile"))) {
                    selected = profile_ids.length;
                }
                names.append (p.name);
                profile_ids += p.id;
            }
            profile_row.notify["selected"].disconnect (on_profile_selected);
            profile_row.model = names;
            profile_row.selected = selected;
            profile_row.notify["selected"].connect (on_profile_selected);

            folders = found_folders;
            selected = 0;
            for (var i = 0; i < folders.length; i++) {
                if (folders[i] == settings.get_string (sync.key ("root-folder"))) {
                    selected = i;
                }
            }
            folder_row.notify["selected"].disconnect (on_folder_selected);
            folder_row.model = new Gtk.StringList (folders);
            folder_row.selected = selected;
            folder_row.notify["selected"].connect (on_folder_selected);
            update_destination_rows ();
        }

        private void on_profile_selected () {
            var i = profile_row.selected;
            if (i < profile_ids.length) {
                settings.set_int64 (sync.key ("quality-profile"), profile_ids[i]);
            }
        }

        private void on_folder_selected () {
            var i = folder_row.selected;
            if (i < folders.length) {
                settings.set_string (sync.key ("root-folder"), folders[i]);
            }
        }

        /* They only matter when titles are added to the service, and once there's something to pick */
        private void update_destination_rows () {
            var writable = !read_only_row.active;
            profile_row.sensitive = writable && profile_ids.length > 0;
            folder_row.sensitive = writable && folders.length > 0;
        }

        [GtkCallback]
        private void on_api_key_apply () {
            save_secret.begin ("api-key", api_key_row.text, _("API key saved"));
        }

        [GtkCallback]
        private void on_password_apply () {
            save_secret.begin ("password", password_row.text, _("Password saved"));
        }

        private async void save_secret (string account, string secret, string message) {
            try {
                yield sync.set_secret (account, secret);
                toast (message);
            } catch (Error e) {
                toast (_("Can’t save to the keyring: %s").printf (e.message));
                return;
            }
            if (!disposed) {
                yield load_destinations ();
            }
        }

        private void update_status () {
            spinner.visible = sync.syncing;
            sync_button.sensitive = !sync.syncing;
            if (sync.syncing) {
                status_row.subtitle = _("Syncing…");
            } else if (sync.last_error != null) {
                status_row.subtitle = _("Failed: %s").printf (sync.last_error);
            } else if (sync.last_sync == 0) {
                status_row.subtitle = _("Never");
            } else {
                var time = new DateTime.from_unix_local (sync.last_sync);
                // xgettext:no-c-format
                status_row.subtitle = time.format (_("%b %-d, %Y at %H:%M"));
            }
        }

        [GtkCallback]
        private void on_sync_clicked () {
            sync_now.begin ();
        }

        private async void sync_now () {
            // Secrets typed but not applied yet are what the user means to use
            try {
                if (api_key_row.text != "") {
                    yield sync.set_secret ("api-key", api_key_row.text);
                }
                if (password_row.text != "") {
                    yield sync.set_secret ("password", password_row.text);
                }
            } catch (Error e) {
                warning ("Can't save %s's secrets: %s", sync.service, e.message);
            }
            ArrSyncResult result;
            try {
                result = yield sync.sync ();
            } catch (Error e) {
                // Shown in the status row
                return;
            }
            string[] parts = {};
            if (result.titles_added > 0) {
                parts += ngettext ("%d title added", "%d titles added", result.titles_added).printf (result.titles_added);
            }
            if (result.titles_sent > 0) {
                // Translators: e.g. "2 sent to Radarr"
                parts += ngettext ("%d sent to %s", "%d sent to %s", result.titles_sent)
                         .printf (result.titles_sent, sync.service);
            }
            if (result.titles_failed > 0) {
                // Translators: e.g. "1 not accepted by Sonarr"
                parts += ngettext ("%d not accepted by %s", "%d not accepted by %s", result.titles_failed)
                         .printf (result.titles_failed, sync.service);
            }
            // Translators: separates the counts in "2 titles added, 1 sent to Radarr"
            toast (parts.length > 0 ? string.joinv (_(", "), parts) : _("Library is already up to date"));
            if (!disposed && profile_ids.length == 0) {
                yield load_destinations ();
            }
        }
    }
}
