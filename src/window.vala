namespace Aperture {
    [GtkTemplate (ui = "/io/github/jonnsl/Aperture/window.ui")]
    public class Window : Adw.ApplicationWindow {
        private Settings settings;

        public Window (Gtk.Application app) {
            Object (application: app);
        }

        construct {
            if (Config.PROFILE == "development") {
                add_css_class ("devel");
            }

            settings = new Settings (Config.APPLICATION_ID);
            settings.bind ("window-width", this, "default-width", SettingsBindFlags.DEFAULT);
            settings.bind ("window-height", this, "default-height", SettingsBindFlags.DEFAULT);
            settings.bind ("window-maximized", this, "maximized", SettingsBindFlags.DEFAULT);
        }
    }
}
