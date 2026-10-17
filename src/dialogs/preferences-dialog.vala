namespace Aperture {
    [GtkTemplate (ui = "/io/github/jonnsl/Aperture/dialogs/preferences-dialog.ui")]
    public class PreferencesDialog : Adw.PreferencesDialog {
        [GtkChild] private unowned Adw.SwitchRow refresh_row;
        [GtkChild] private unowned Adw.SwitchRow custom_key_row;
        [GtkChild] private unowned Adw.PasswordEntryRow api_key_row;
        [GtkChild] private unowned Adw.ActionRow cache_row;

        private Settings settings;

        construct {
            settings = new Settings (Config.APPLICATION_ID);
            settings.bind ("refresh-automatically", refresh_row, "active", SettingsBindFlags.DEFAULT);
            settings.bind ("use-custom-api-key", custom_key_row, "active", SettingsBindFlags.DEFAULT);
            settings.bind ("custom-api-key", api_key_row, "text", SettingsBindFlags.DEFAULT);
            update_cache_size.begin ();
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
                initial_name = "aperture-library-%s.json".printf (new DateTime.now_local ().format ("%F")),
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
