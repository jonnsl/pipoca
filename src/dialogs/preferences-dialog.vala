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

        private async void clear_cache () {
            yield ImageCache.get_default ().clear ();
            yield update_cache_size ();
            add_toast (new Adw.Toast (_("Image cache cleared")));
        }
    }
}
