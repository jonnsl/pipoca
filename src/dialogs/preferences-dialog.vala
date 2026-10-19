namespace Pipoca {
    [GtkTemplate (ui = "/io/github/jonnsl/Pipoca/dialogs/preferences-dialog.ui")]
    public class PreferencesDialog : Adw.PreferencesDialog {
        [GtkChild] private unowned Adw.ComboRow language_row;
        [GtkChild] private unowned Adw.SwitchRow spoilers_row;
        [GtkChild] private unowned Adw.ComboRow spoiler_level_row;
        [GtkChild] private unowned Adw.SwitchRow refresh_row;
        [GtkChild] private unowned Adw.SwitchRow notify_episodes_row;
        [GtkChild] private unowned Adw.SwitchRow notify_movies_row;
        [GtkChild] private unowned Adw.SwitchRow background_row;
        [GtkChild] private unowned Adw.SwitchRow custom_key_row;
        [GtkChild] private unowned Adw.PasswordEntryRow api_key_row;
        [GtkChild] private unowned Adw.ActionRow cache_row;
        [GtkChild] private unowned Adw.SwitchRow kodi_enabled_row;
        [GtkChild] private unowned Adw.ComboRow kodi_interval_row;
        [GtkChild] private unowned Adw.EntryRow kodi_address_row;
        [GtkChild] private unowned Adw.EntryRow kodi_username_row;
        [GtkChild] private unowned Adw.PasswordEntryRow kodi_password_row;
        [GtkChild] private unowned Adw.ActionRow kodi_status_row;
        [GtkChild] private unowned Adw.Spinner kodi_spinner;
        [GtkChild] private unowned Gtk.Button kodi_sync_button;
        [GtkChild] private unowned Adw.SwitchRow radarr_enabled_row;
        [GtkChild] private unowned Adw.ComboRow radarr_interval_row;
        [GtkChild] private unowned Adw.SwitchRow radarr_read_only_row;
        [GtkChild] private unowned Adw.EntryRow radarr_address_row;
        [GtkChild] private unowned Adw.PasswordEntryRow radarr_api_key_row;
        [GtkChild] private unowned Adw.EntryRow radarr_username_row;
        [GtkChild] private unowned Adw.PasswordEntryRow radarr_password_row;
        [GtkChild] private unowned Adw.SwitchRow radarr_certificate_row;
        [GtkChild] private unowned Adw.ComboRow radarr_profile_row;
        [GtkChild] private unowned Adw.ComboRow radarr_folder_row;
        [GtkChild] private unowned Adw.ActionRow radarr_status_row;
        [GtkChild] private unowned Adw.Spinner radarr_spinner;
        [GtkChild] private unowned Gtk.Button radarr_sync_button;
        [GtkChild] private unowned Adw.ButtonRow imdb_row;

        /* TMDB languages with translations, as tag and the language's own name */
        private const string[] LANGUAGES = {
            "ar-SA", "العربية",
            "bg-BG", "Български",
            "ca-ES", "Català",
            "cs-CZ", "Čeština",
            "da-DK", "Dansk",
            "de-DE", "Deutsch",
            "el-GR", "Ελληνικά",
            "en-US", "English (US)",
            "en-GB", "English (UK)",
            "es-ES", "Español (España)",
            "es-MX", "Español (México)",
            "fa-IR", "فارسی",
            "fi-FI", "Suomi",
            "fr-FR", "Français (France)",
            "fr-CA", "Français (Canada)",
            "he-IL", "עברית",
            "hi-IN", "हिन्दी",
            "hu-HU", "Magyar",
            "id-ID", "Bahasa Indonesia",
            "it-IT", "Italiano",
            "ja-JP", "日本語",
            "ko-KR", "한국어",
            "nb-NO", "Norsk bokmål",
            "nl-NL", "Nederlands",
            "pl-PL", "Polski",
            "pt-BR", "Português (Brasil)",
            "pt-PT", "Português (Portugal)",
            "ro-RO", "Română",
            "ru-RU", "Русский",
            "sk-SK", "Slovenčina",
            "sr-RS", "Српски",
            "sv-SE", "Svenska",
            "th-TH", "ไทย",
            "tr-TR", "Türkçe",
            "uk-UA", "Українська",
            "vi-VN", "Tiếng Việt",
            "zh-CN", "中文（中国）",
            "zh-TW", "中文（台灣）",
            "zh-HK", "中文（香港）",
        };

        /* spoiler-level for each spoiler_level_row choice */
        private const string[] SPOILER_LEVELS = { "images", "details" };

        /* Minutes for each kodi_interval_row and radarr_interval_row choice */
        private const int[] SYNC_INTERVALS = { 15, 60, 360, 1440 };

        private Settings settings;
        /* Imports keep going after the dialog is closed */
        private bool disposed;
        /* Tag for each language_row choice; "" for the system language */
        private string[] language_tags = {};
        /* Radarr's quality profile ids and root folders, in the order of their rows' choices */
        private int64[] radarr_profile_ids = {};
        private string[] radarr_folders = {};

        construct {
            settings = new Settings (Config.APPLICATION_ID);
            setup_language ();
            setup_spoilers ();
            settings.bind ("refresh-automatically", refresh_row, "active", SettingsBindFlags.DEFAULT);
            settings.bind ("notify-new-episodes", notify_episodes_row, "active", SettingsBindFlags.DEFAULT);
            settings.bind ("notify-movie-releases", notify_movies_row, "active", SettingsBindFlags.DEFAULT);
            // Turning it on needs permission first, so it isn't bound directly
            background_row.active = settings.get_boolean ("run-in-background");
            background_row.notify["active"].connect (on_background_toggled);
            settings.bind ("use-custom-api-key", custom_key_row, "active", SettingsBindFlags.DEFAULT);
            settings.bind ("custom-api-key", api_key_row, "text", SettingsBindFlags.DEFAULT);
            update_cache_size.begin ();
            setup_kodi ();
            setup_radarr ();
        }

        public override void dispose () {
            disposed = true;
            var kodi = KodiSync.get_default ();
            kodi.notify["syncing"].disconnect (update_kodi_status);
            kodi.notify["last-error"].disconnect (update_kodi_status);
            var radarr = RadarrSync.get_default ();
            radarr.notify["syncing"].disconnect (update_radarr_status);
            radarr.notify["last-error"].disconnect (update_radarr_status);
            dispose_template (typeof (PreferencesDialog));
            base.dispose ();
        }

        private string language_name (string tag) {
            for (var i = 0; i + 1 < LANGUAGES.length; i += 2) {
                if (LANGUAGES[i] == tag) {
                    return LANGUAGES[i + 1];
                }
            }
            return tag;
        }

        private void setup_language () {
            var names = new Gtk.StringList (null);
            names.append (_("System (%s)").printf (language_name (TmdbClient.detect_language ())));
            language_tags += "";
            for (var i = 0; i + 1 < LANGUAGES.length; i += 2) {
                names.append (LANGUAGES[i + 1]);
                language_tags += LANGUAGES[i];
            }
            // Set by hand to something not listed
            var current = settings.get_string ("metadata-language");
            if (current != "" && !(current in language_tags)) {
                names.append (current);
                language_tags += current;
            }
            language_row.model = names;
            language_row.expression = new Gtk.PropertyExpression (typeof (Gtk.StringObject), null, "string");
            for (var i = 0; i < language_tags.length; i++) {
                if (language_tags[i] == current) {
                    language_row.selected = i;
                }
            }
            language_row.notify["selected"].connect (on_language_selected);
        }

        private void on_language_selected () {
            var tag = language_tags[language_row.selected];
            if (tag == settings.get_string ("metadata-language")) {
                return;
            }
            settings.set_string ("metadata-language", tag);
            var library = Library.get_default ();
            if (!library.needs_relocalizing ()) {
                return;
            }
            // Titles already stored are in the old language until refreshed
            if (NetworkMonitor.get_default ().network_available) {
                library.refresh_library.begin (false);
                add_toast (new Adw.Toast (_("Updating titles to the new language…")));
            } else {
                add_toast (new Adw.Toast (_("Titles will be updated to the new language when you’re online")));
            }
        }

        private void setup_spoilers () {
            settings.bind ("hide-spoilers", spoilers_row, "active", SettingsBindFlags.DEFAULT);
            var level = settings.get_string ("spoiler-level");
            for (var i = 0; i < SPOILER_LEVELS.length; i++) {
                if (SPOILER_LEVELS[i] == level) {
                    spoiler_level_row.selected = i;
                }
            }
            spoiler_level_row.notify["selected"].connect (() => {
                settings.set_string ("spoiler-level", SPOILER_LEVELS[spoiler_level_row.selected]);
            });
        }

        private void on_background_toggled () {
            if (background_row.active != settings.get_boolean ("run-in-background")) {
                set_run_in_background.begin (background_row.active);
            }
        }

        private async void set_run_in_background (bool enabled) {
            background_row.sensitive = false;
            var allowed = false;
            try {
                allowed = yield Background.request (_("Pipoca checks for new episodes and releases to notify you about"), enabled);
            } catch (IOError.CANCELLED e) {
                // The user dismissed the request
            } catch (Error e) {
                warning ("Can't request to run in the background: %s", e.message);
            }
            if (enabled && !allowed) {
                add_toast (new Adw.Toast (_("Pipoca isn’t allowed to run in the background")));
            }
            // Turning it off always works; autostart is just left in place if removing it failed
            settings.set_boolean ("run-in-background", enabled && allowed);
            background_row.active = settings.get_boolean ("run-in-background");
            background_row.sensitive = true;
        }

        private void setup_kodi () {
            settings.bind ("kodi-enabled", kodi_enabled_row, "active", SettingsBindFlags.DEFAULT);
            settings.bind ("kodi-address", kodi_address_row, "text", SettingsBindFlags.DEFAULT);
            settings.bind ("kodi-username", kodi_username_row, "text", SettingsBindFlags.DEFAULT);

            var minutes = settings.get_int ("kodi-sync-interval");
            kodi_interval_row.selected = 1;
            for (var i = 0; i < SYNC_INTERVALS.length; i++) {
                if (SYNC_INTERVALS[i] == minutes) {
                    kodi_interval_row.selected = i;
                }
            }
            kodi_interval_row.notify["selected"].connect (() => {
                settings.set_int ("kodi-sync-interval", SYNC_INTERVALS[kodi_interval_row.selected]);
            });

            var kodi = KodiSync.get_default ();
            kodi.notify["syncing"].connect (update_kodi_status);
            kodi.notify["last-error"].connect (update_kodi_status);
            update_kodi_status ();
            load_kodi_password.begin ();
        }

        private async void load_kodi_password () {
            try {
                kodi_password_row.text = (yield KodiSync.get_default ().get_password ()) ?? "";
            } catch (Error e) {
                warning ("Can't read the Kodi password from the keyring: %s", e.message);
            }
        }

        [GtkCallback]
        private void on_kodi_password_apply () {
            save_kodi_password.begin (kodi_password_row.text);
        }

        private async void save_kodi_password (string password) {
            try {
                yield KodiSync.get_default ().set_password (password);
                add_toast (new Adw.Toast (_("Password saved")));
            } catch (Error e) {
                show_error (_("Can’t Save Password"), e.message);
            }
        }

        private void update_kodi_status () {
            var kodi = KodiSync.get_default ();
            kodi_spinner.visible = kodi.syncing;
            kodi_sync_button.sensitive = !kodi.syncing;
            if (kodi.syncing) {
                kodi_status_row.subtitle = _("Syncing…");
            } else if (kodi.last_error != null) {
                kodi_status_row.subtitle = _("Failed: %s").printf (kodi.last_error);
            } else if (kodi.last_sync == 0) {
                kodi_status_row.subtitle = _("Never");
            } else {
                var time = new DateTime.from_unix_local (kodi.last_sync);
                // Translators: date and time of the last sync, see https://docs.gtk.org/glib/method.DateTime.format.html
                // xgettext:no-c-format
                kodi_status_row.subtitle = time.format (_("%b %-d, %Y at %H:%M"));
            }
        }

        [GtkCallback]
        private void on_kodi_sync_clicked () {
            sync_kodi.begin ();
        }

        private async void sync_kodi () {
            // A password typed but not applied yet is what the user means to use
            if (kodi_password_row.text != "") {
                try {
                    yield KodiSync.get_default ().set_password (kodi_password_row.text);
                } catch (Error e) {
                    warning ("Can't save the Kodi password: %s", e.message);
                }
            }
            try {
                var result = yield KodiSync.get_default ().sync ();
                string message;
                if (result.titles_added == 0 && result.events_added == 0) {
                    message = _("Library is already up to date");
                } else {
                    message = _("%s, %s").printf (
                        ngettext ("%d title added", "%d titles added", result.titles_added).printf (result.titles_added),
                        ngettext ("%d watch marked", "%d watches marked", result.events_added).printf (result.events_added));
                }
                add_toast (new Adw.Toast (message));
            } catch (Error e) {
                // Shown in the status row
            }
        }

        private void setup_radarr () {
            settings.bind ("radarr-enabled", radarr_enabled_row, "active", SettingsBindFlags.DEFAULT);
            settings.bind ("radarr-read-only", radarr_read_only_row, "active", SettingsBindFlags.DEFAULT);
            settings.bind ("radarr-address", radarr_address_row, "text", SettingsBindFlags.DEFAULT);
            settings.bind ("radarr-username", radarr_username_row, "text", SettingsBindFlags.DEFAULT);
            settings.bind ("radarr-accept-any-certificate", radarr_certificate_row, "active", SettingsBindFlags.DEFAULT);

            var minutes = settings.get_int ("radarr-sync-interval");
            radarr_interval_row.selected = 1;
            for (var i = 0; i < SYNC_INTERVALS.length; i++) {
                if (SYNC_INTERVALS[i] == minutes) {
                    radarr_interval_row.selected = i;
                }
            }
            radarr_interval_row.notify["selected"].connect (() => {
                settings.set_int ("radarr-sync-interval", SYNC_INTERVALS[radarr_interval_row.selected]);
            });
            radarr_read_only_row.notify["active"].connect (update_radarr_destination_rows);

            var radarr = RadarrSync.get_default ();
            radarr.notify["syncing"].connect (update_radarr_status);
            radarr.notify["last-error"].connect (update_radarr_status);
            update_radarr_status ();
            load_radarr_secrets.begin ();
        }

        private async void load_radarr_secrets () {
            var radarr = RadarrSync.get_default ();
            try {
                radarr_api_key_row.text = (yield radarr.get_secret ("api-key")) ?? "";
                radarr_password_row.text = (yield radarr.get_secret ("password")) ?? "";
            } catch (Error e) {
                warning ("Can't read Radarr's secrets from the keyring: %s", e.message);
            }
            if (!disposed && radarr_api_key_row.text != "" && radarr_address_row.text != "") {
                yield load_radarr_destinations ();
            }
        }

        /* Fills the quality profile and root folder rows with what Radarr has */
        private async void load_radarr_destinations () {
            GenericArray<RadarrQualityProfile> profiles;
            string[] folders;
            try {
                var client = yield RadarrSync.get_default ().make_client ();
                profiles = yield client.get_quality_profiles ();
                folders = yield client.get_root_folders ();
            } catch (Error e) {
                debug ("Can't load Radarr's quality profiles and root folders: %s", e.message);
                return;
            }
            if (disposed) {
                return;
            }

            // Radarr's first one is what a sync uses when the chosen one is gone
            var names = new Gtk.StringList (null);
            radarr_profile_ids = {};
            uint selected = 0;
            foreach (var p in profiles) {
                if (p.id == settings.get_int64 ("radarr-quality-profile")) {
                    selected = radarr_profile_ids.length;
                }
                names.append (p.name);
                radarr_profile_ids += p.id;
            }
            radarr_profile_row.notify["selected"].disconnect (on_radarr_profile_selected);
            radarr_profile_row.model = names;
            radarr_profile_row.selected = selected;
            radarr_profile_row.notify["selected"].connect (on_radarr_profile_selected);

            radarr_folders = folders;
            selected = 0;
            for (var i = 0; i < folders.length; i++) {
                if (folders[i] == settings.get_string ("radarr-root-folder")) {
                    selected = i;
                }
            }
            radarr_folder_row.notify["selected"].disconnect (on_radarr_folder_selected);
            radarr_folder_row.model = new Gtk.StringList (folders);
            radarr_folder_row.selected = selected;
            radarr_folder_row.notify["selected"].connect (on_radarr_folder_selected);
            update_radarr_destination_rows ();
        }

        private void on_radarr_profile_selected () {
            var i = radarr_profile_row.selected;
            if (i < radarr_profile_ids.length) {
                settings.set_int64 ("radarr-quality-profile", radarr_profile_ids[i]);
            }
        }

        private void on_radarr_folder_selected () {
            var i = radarr_folder_row.selected;
            if (i < radarr_folders.length) {
                settings.set_string ("radarr-root-folder", radarr_folders[i]);
            }
        }

        /* They only matter when movies are added to Radarr, and once there's something to pick */
        private void update_radarr_destination_rows () {
            var writable = !radarr_read_only_row.active;
            radarr_profile_row.sensitive = writable && radarr_profile_ids.length > 0;
            radarr_folder_row.sensitive = writable && radarr_folders.length > 0;
        }

        [GtkCallback]
        private void on_radarr_api_key_apply () {
            save_radarr_secret.begin ("api-key", radarr_api_key_row.text, _("API key saved"));
        }

        [GtkCallback]
        private void on_radarr_password_apply () {
            save_radarr_secret.begin ("password", radarr_password_row.text, _("Password saved"));
        }

        private async void save_radarr_secret (string account, string secret, string message) {
            try {
                yield RadarrSync.get_default ().set_secret (account, secret);
                add_toast (new Adw.Toast (message));
            } catch (Error e) {
                show_error (_("Can’t Save to the Keyring"), e.message);
                return;
            }
            yield load_radarr_destinations ();
        }

        private void update_radarr_status () {
            var radarr = RadarrSync.get_default ();
            radarr_spinner.visible = radarr.syncing;
            radarr_sync_button.sensitive = !radarr.syncing;
            if (radarr.syncing) {
                radarr_status_row.subtitle = _("Syncing…");
            } else if (radarr.last_error != null) {
                radarr_status_row.subtitle = _("Failed: %s").printf (radarr.last_error);
            } else if (radarr.last_sync == 0) {
                radarr_status_row.subtitle = _("Never");
            } else {
                var time = new DateTime.from_unix_local (radarr.last_sync);
                // xgettext:no-c-format
                radarr_status_row.subtitle = time.format (_("%b %-d, %Y at %H:%M"));
            }
        }

        [GtkCallback]
        private void on_radarr_sync_clicked () {
            sync_radarr.begin ();
        }

        private async void sync_radarr () {
            // Secrets typed but not applied yet are what the user means to use
            var radarr = RadarrSync.get_default ();
            try {
                if (radarr_api_key_row.text != "") {
                    yield radarr.set_secret ("api-key", radarr_api_key_row.text);
                }
                if (radarr_password_row.text != "") {
                    yield radarr.set_secret ("password", radarr_password_row.text);
                }
            } catch (Error e) {
                warning ("Can't save Radarr's secrets: %s", e.message);
            }
            RadarrSyncResult result;
            try {
                result = yield radarr.sync ();
            } catch (Error e) {
                // Shown in the status row
                return;
            }
            string[] parts = {};
            if (result.titles_added > 0) {
                parts += ngettext ("%d title added", "%d titles added", result.titles_added).printf (result.titles_added);
            }
            if (result.titles_sent > 0) {
                parts += ngettext ("%d sent to Radarr", "%d sent to Radarr", result.titles_sent).printf (result.titles_sent);
            }
            if (result.titles_failed > 0) {
                parts += ngettext ("%d not accepted by Radarr", "%d not accepted by Radarr", result.titles_failed)
                         .printf (result.titles_failed);
            }
            // Translators: separates the counts in "2 titles added, 1 sent to Radarr"
            show_toast (parts.length > 0 ? string.joinv (_(", "), parts) : _("Library is already up to date"));
            if (!disposed && radarr_profile_ids.length == 0) {
                yield load_radarr_destinations ();
            }
        }

        private async void update_cache_size () {
            var size = yield ImageCache.get_default ().get_size ();
            cache_row.subtitle = format_size (size);
        }

        [GtkCallback]
        private void on_clear_cache_clicked () {
            var dialog = new Adw.AlertDialog (_("Clear Image Cache?"),
                                              _("Posters and backdrops will be downloaded again when needed"));
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("clear", _("C_lear"));
            dialog.set_response_appearance ("clear", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            dialog.response.connect ((response) => {
                if (response == "clear") {
                    clear_cache.begin ();
                }
            });
            dialog.present (this);
        }

        private Gtk.FileFilter json_filter () {
            var filter = new Gtk.FileFilter () { name = _("Library Files") };
            filter.add_mime_type ("application/json");
            filter.add_suffix ("json");
            return filter;
        }

        [GtkCallback]
        private void on_export_activated () {
            export_library.begin ();
        }

        private async void export_library () {
            var dialog = new Gtk.FileDialog () {
                title = _("Export Library"),
                initial_name = "pipoca-library-%s.json".printf (new DateTime.now_local ().format ("%F")),
                default_filter = json_filter (),
            };
            try {
                var file = yield dialog.save (get_root () as Gtk.Window, null);
                var data = LibraryTransfer.export_json (Library.get_default ());
                yield file.replace_contents_async (data.data, null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
                add_toast (new Adw.Toast (_("Library exported")));
            } catch (Gtk.DialogError.DISMISSED e) {
                // Cancelled
            } catch (Error e) {
                show_error (_("Can’t Export Library"), e.message);
            }
        }

        [GtkCallback]
        private void on_import_activated () {
            import_library.begin ();
        }

        private async void import_library () {
            var filters = new ListStore (typeof (Gtk.FileFilter));
            filters.append (json_filter ());
            var dialog = new Gtk.FileDialog () {
                title = _("Import Library"),
                filters = filters,
            };
            try {
                var file = yield dialog.open (get_root () as Gtk.Window, null);
                uint8[] contents;
                yield file.load_contents_async (null, out contents, null);
                var library = Library.get_default ();
                var result = LibraryTransfer.import_json (library, (string) contents);
                string message;
                if (result.titles_added == 0 && result.events_added == 0) {
                    message = _("Library is already up to date");
                } else {
                    message = ngettext ("Imported %d title", "Imported %d titles", result.titles_added)
                              .printf (result.titles_added);
                }
                add_toast (new Adw.Toast (message));
                if (result.titles_added > 0) {
                    // Imported titles only have the basics; fetch the rest
                    library.refresh_library.begin (false);
                }
            } catch (Gtk.DialogError.DISMISSED e) {
                // Cancelled
            } catch (Error e) {
                show_error (_("Can’t Import Library"), e.message);
            }
        }

        [GtkCallback]
        private void on_imdb_activated () {
            import_imdb.begin ();
        }

        private async void import_imdb () {
            var csv = new Gtk.FileFilter () { name = _("IMDb Exports") };
            csv.add_mime_type ("text/csv");
            csv.add_suffix ("csv");
            var filters = new ListStore (typeof (Gtk.FileFilter));
            filters.append (csv);
            var dialog = new Gtk.FileDialog () {
                title = _("Import from IMDb"),
                filters = filters,
            };
            var library = Library.get_default ();
            try {
                var file = yield dialog.open (get_root () as Gtk.Window, null);
                uint8[] contents;
                yield file.load_contents_async (null, out contents, null);
                GenericArray<ImdbItem> items;
                var kind = ImdbImport.parse ((string) contents, out items);
                if (items.length == 0) {
                    add_toast (new Adw.Toast (_("This export has no titles")));
                    return;
                }
                // A list can be the watchlist or titles seen; only the user knows
                var as_watched = true;
                if (kind == ImdbFileKind.LIST) {
                    var choice = yield ask_list_kind ();
                    if (choice == "cancel") {
                        return;
                    }
                    as_watched = choice == "watched";
                }

                var title = imdb_row.title;
                imdb_row.sensitive = false;
                try {
                    yield ImdbImport.find_all (library.tmdb, items, (done, total) => {
                        if (!disposed) {
                            imdb_row.title = _("Looking up titles… %d of %d").printf (done, total);
                        }
                    }, null);
                } finally {
                    if (!disposed) {
                        imdb_row.title = title;
                        imdb_row.sensitive = true;
                    }
                }

                var matches = new GenericArray<ImdbMatch> ();
                foreach (var item in items) {
                    if (item.match != null) {
                        matches.add (item.match);
                    }
                }
                var result = ImdbImport.apply (library, matches, as_watched);
                string message;
                if (result.titles_added == 0 && result.events_added == 0) {
                    message = _("Library is already up to date");
                } else {
                    message = _("%s, %s").printf (
                        ngettext ("%d title added", "%d titles added", result.titles_added).printf (result.titles_added),
                        ngettext ("%d watch marked", "%d watches marked", result.events_added).printf (result.events_added));
                }
                var unmatched = items.length - matches.length;
                if (unmatched > 0) {
                    message = _("%s · %s").printf (message,
                        ngettext ("%d not found on TMDB", "%d not found on TMDB", unmatched).printf (unmatched));
                }
                show_toast (message);
                if (result.titles_added > 0) {
                    // Imported titles only have the basics; fetch the rest
                    library.refresh_library.begin (false);
                }
            } catch (Gtk.DialogError.DISMISSED e) {
                // Cancelled
            } catch (Error e) {
                if (disposed) {
                    show_toast (_("Can’t import from IMDb: %s").printf (e.message));
                } else {
                    show_error (_("Can’t Import from IMDb"), e.message);
                }
            }
        }

        /* "watched", "watchlist" or "cancel" */
        private async string ask_list_kind () {
            var alert = new Adw.AlertDialog (_("Import IMDb List?"),
                                             _("Mark the titles in this list as watched, on the day they were added to it, or add them to your watchlist"));
            alert.add_response ("cancel", _("_Cancel"));
            alert.add_response ("watchlist", _("Add to _Watchlist"));
            alert.add_response ("watched", _("Mark as W_atched"));
            alert.set_response_appearance ("watched", Adw.ResponseAppearance.SUGGESTED);
            alert.default_response = "watched";
            alert.close_response = "cancel";
            return yield alert.choose (this, null);
        }

        /* On the dialog, or the window once the dialog is closed */
        private void show_toast (string message) {
            if (!disposed) {
                add_toast (new Adw.Toast (message));
                return;
            }
            var app = GLib.Application.get_default () as Gtk.Application;
            var win = app != null ? app.active_window as Window : null;
            if (win != null) {
                win.add_toast (new Adw.Toast (message));
            }
        }

        private void show_error (string heading, string body) {
            var alert = new Adw.AlertDialog (heading, body);
            alert.add_response ("close", _("_Close"));
            alert.present (this);
        }

        private async void clear_cache () {
            yield ImageCache.get_default ().clear ();
            yield update_cache_size ();
            add_toast (new Adw.Toast (_("Image cache cleared")));
        }
    }
}
