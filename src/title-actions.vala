namespace Aperture.TitleActions {
    /* Actions on titles shared by cards, rows and pages. Reversible ones offer Undo in a toast. */

    private void toast (Gtk.Widget source, Adw.Toast toast) {
        // Dialogs have their own overlay so toasts aren't hidden behind them
        var overlay = source.get_ancestor (typeof (Adw.ToastOverlay)) as Adw.ToastOverlay;
        if (overlay != null) {
            overlay.add_toast (toast);
            return;
        }
        var win = Window.of (source);
        if (win != null) {
            win.add_toast (toast);
        }
    }

    private Adw.Toast undo_toast (string title, owned VoidFunc undo) {
        var t = new Adw.Toast (title) {
            button_label = _("_Undo"),
            use_markup = false,
        };
        t.button_clicked.connect (() => undo ());
        return t;
    }

    public delegate void VoidFunc ();

    public void add (Gtk.Widget source, Title t) {
        var library = Library.get_default ();
        library.add (t);
        toast (source, undo_toast (_("Added to Watchlist"), () => library.remove (t)));
    }

    public void remove (Gtk.Widget source, Title t) {
        var library = Library.get_default ();
        var dropped_at = t.dropped_at;
        library.remove (t);
        toast (source, undo_toast (_("“%s” removed from library").printf (t.name), () => {
            library.add (t);
            if (dropped_at > 0) {
                library.set_dropped (t, true, dropped_at);
            }
        }));
    }

    public void set_dropped (Gtk.Widget source, Title t, bool dropped) {
        var library = Library.get_default ();
        var dropped_at = t.dropped_at;
        library.set_dropped (t, dropped);
        var title = dropped ? _("“%s” dropped").printf (t.name) : _("“%s” resumed").printf (t.name);
        toast (source, undo_toast (title, () => library.set_dropped (t, !dropped, dropped_at)));
    }

    public void set_movie_watched (Gtk.Widget source, Title t, bool watched) {
        var library = Library.get_default ();
        var was_in_library = t.in_library;
        var dropped_at = t.dropped_at;
        library.set_movie_watched (t, watched);
        var title = watched ? _("Marked as watched") : _("Marked as unwatched");
        toast (source, undo_toast (title, () => {
            library.set_movie_watched (t, !watched);
            restore (t, was_in_library, dropped_at);
        }));
    }

    /* Undoes the side effects of marking something watched: adding and resuming */
    private void restore (Title t, bool was_in_library, int64 dropped_at) {
        var library = Library.get_default ();
        if (!was_in_library) {
            library.remove (t);
        } else if (dropped_at > 0) {
            library.set_dropped (t, true, dropped_at);
        }
    }

    public void mark_episodes (Gtk.Widget source, Title show, GenericArray<Episode> episodes, bool watched) {
        var library = Library.get_default ();
        var was_in_library = show.in_library;
        var dropped_at = show.dropped_at;
        var changed = library.set_episodes_watched (show, episodes, watched);
        if (changed.length == 0) {
            return;
        }
        string title;
        if (changed.length == 1) {
            title = (watched ? _("%s marked as watched") : _("%s marked as unwatched")).printf (changed[0].code);
        } else {
            title = (watched ? ngettext ("%d episode marked as watched", "%d episodes marked as watched", changed.length)
                             : ngettext ("%d episode marked as unwatched", "%d episodes marked as unwatched", changed.length))
                    .printf (changed.length);
        }
        toast (source, undo_toast (title, () => {
            library.set_episodes_watched (show, changed, !watched);
            restore (show, was_in_library, dropped_at);
        }));
    }

    public void mark_next_watched (Gtk.Widget source, Title show) {
        if (show.next_episode == null) {
            return;
        }
        var eps = new GenericArray<Episode> ();
        eps.add (show.next_episode);
        mark_episodes (source, show, eps, true);
    }

    public void open_on_tmdb (Gtk.Widget source, Title t) {
        var launcher = new Gtk.UriLauncher (t.tmdb_url);
        launcher.launch.begin (source.get_root () as Gtk.Window, null, (obj, res) => {
            try {
                launcher.launch.end (res);
            } catch (Error e) {
                warning ("Can't open %s: %s", t.tmdb_url, e.message);
            }
        });
    }

    public void copy_link (Gtk.Widget source, Title t) {
        source.get_clipboard ().set_text (t.tmdb_url);
        toast (source, new Adw.Toast (_("Link copied")));
    }

    /* The context menu for a title; the actions are installed by the widget showing it */
    public Menu build_menu (Title t, string prefix) {
        var menu = new Menu ();
        var watch = new Menu ();
        if (t.is_movie) {
            watch.append (t.movie_watched ? _("Mark as _Unwatched") : _("Mark as _Watched"), prefix + ".toggle-watched");
        } else if (t.next_episode != null) {
            watch.append (_("Mark %s as _Watched").printf (t.next_episode.code), prefix + ".mark-next");
        }
        menu.append_section (null, watch);
        var library = new Menu ();
        if (t.in_library) {
            if (t.is_dropped) {
                library.append (_("Resu_me Watching"), prefix + ".resume");
            } else {
                library.append (_("_Drop"), prefix + ".drop");
            }
            library.append (_("_Remove from Library"), prefix + ".remove");
        } else {
            library.append (_("_Add to Watchlist"), prefix + ".add");
        }
        library.append (_("_Open on TMDB"), prefix + ".open-tmdb");
        menu.append_section (null, library);
        return menu;
    }
}
