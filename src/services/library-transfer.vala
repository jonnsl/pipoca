namespace Aperture {
    public errordomain TransferError {
        INVALID_FORMAT,
        UNSUPPORTED_VERSION,
    }

    public struct ImportResult {
        public int titles_added;
        public int titles_skipped;
        public int events_added;
    }

    /**
     * Exports and imports the library as JSON. The format is documented in
     * docs/LIBRARY_FORMAT.md; keep the two in sync.
     */
    namespace LibraryTransfer {
        public const string FORMAT = "aperture-library";
        public const int VERSION = 1;

        public string export_json (Library library) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("format").add_string_value (FORMAT);
            b.set_member_name ("version").add_int_value (VERSION);
            b.set_member_name ("exported_at").add_string_value (format_time (new DateTime.now_utc ().to_unix ()));
            b.set_member_name ("titles").begin_array ();
            for (uint i = 0; i < library.titles.get_n_items (); i++) {
                var t = (Title) library.titles.get_item (i);
                b.begin_object ();
                b.set_member_name ("media_type").add_string_value (t.media_type.to_api_string ());
                b.set_member_name ("tmdb_id").add_int_value (t.id);
                b.set_member_name ("name").add_string_value (t.name);
                if (t.release_date != null) {
                    b.set_member_name ("release_date").add_string_value (t.release_date);
                }
                if (t.poster_path != null) {
                    b.set_member_name ("poster_path").add_string_value (t.poster_path);
                }
                b.set_member_name ("added_at").add_string_value (format_time (t.added_at));
                if (t.is_dropped) {
                    b.set_member_name ("dropped_at").add_string_value (format_time (t.dropped_at));
                }
                b.set_member_name ("watched").begin_array ();
                foreach (var e in library.db.load_watch_events (t.media_type, t.id)) {
                    b.begin_object ();
                    if (!t.is_movie) {
                        b.set_member_name ("season").add_int_value (e.season_number);
                        b.set_member_name ("episode").add_int_value (e.episode_number);
                    }
                    b.set_member_name ("watched_at").add_string_value (format_time (e.watched_at));
                    b.end_object ();
                }
                b.end_array ();
                b.end_object ();
            }
            b.end_array ();
            b.end_object ();

            var gen = new Json.Generator () {
                pretty = true,
                indent = 2,
                root = b.get_root (),
            };
            return gen.to_data (null) + "\n";
        }

        /**
         * Merges an export into the library: missing titles are added and
         * missing watch events recorded. Nothing is removed or overwritten.
         *
         * Imported titles have no details yet; refresh the library afterwards.
         */
        public ImportResult import_json (Library library, string data) throws Error {
            var parser = new Json.Parser ();
            parser.load_from_data (data);
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                throw new TransferError.INVALID_FORMAT (_("This isn’t an Aperture library file"));
            }
            var obj = root.get_object ();
            if (JsonUtil.str (obj, "format") != FORMAT) {
                throw new TransferError.INVALID_FORMAT (_("This isn’t an Aperture library file"));
            }
            var version = JsonUtil.integer (obj, "version");
            if (version < 1 || version > VERSION) {
                throw new TransferError.UNSUPPORTED_VERSION (_("This library file was made by a newer version of Aperture"));
            }
            var titles = JsonUtil.array (obj, "titles");
            if (titles == null) {
                throw new TransferError.INVALID_FORMAT (_("This library file has no titles"));
            }

            var result = ImportResult ();
            var touched = new GenericArray<Title> ();
            var db = library.db;
            db.begin ();
            try {
                for (uint i = 0; i < titles.get_length (); i++) {
                    var node = titles.get_element (i);
                    var t = node.get_node_type () == Json.NodeType.OBJECT
                        ? import_title (library, node.get_object (), ref result)
                        : null;
                    if (t == null) {
                        result.titles_skipped++;
                        continue;
                    }
                    touched.add (t);
                }
                db.commit ();
            } catch (Error e) {
                db.rollback ();
                throw e;
            }

            foreach (var t in touched) {
                library.update_progress (t);
                library.title_changed (t);
                if (!t.is_movie) {
                    library.episodes_changed (t);
                }
            }
            return result;
        }

        private Title? import_title (Library library, Json.Object o, ref ImportResult result) throws Error {
            MediaType type;
            if (!MediaType.try_parse (JsonUtil.str (o, "media_type"), out type)) {
                return null;
            }
            var id = JsonUtil.integer (o, "tmdb_id");
            if (id <= 0) {
                return null;
            }

            var t = library.lookup (type, id);
            if (t == null) {
                t = library.intern (new Title (type, id));
                // Enough to show the title until its details are fetched
                t.name = JsonUtil.str (o, "name") ?? "";
                t.release_date = JsonUtil.str (o, "release_date");
                t.poster_path = JsonUtil.str (o, "poster_path");
            }
            if (!t.in_library) {
                var added_at = parse_time (JsonUtil.str (o, "added_at"));
                if (added_at > 0) {
                    t.added_at = added_at;
                }
                library.add (t, false);
                var dropped_at = parse_time (JsonUtil.str (o, "dropped_at"));
                if (dropped_at > 0) {
                    library.set_dropped (t, true, dropped_at);
                }
                result.titles_added++;
            }

            var watched = JsonUtil.array (o, "watched");
            if (watched == null) {
                return t;
            }
            for (uint i = 0; i < watched.get_length (); i++) {
                var node = watched.get_element (i);
                if (node.get_node_type () != Json.NodeType.OBJECT) {
                    continue;
                }
                var e = node.get_object ();
                var watched_at = parse_time (JsonUtil.str (e, "watched_at"));
                if (watched_at <= 0) {
                    continue;
                }
                int season = -1, episode = -1;
                if (type == MediaType.TV) {
                    if (!e.has_member ("season") || !e.has_member ("episode")) {
                        continue;
                    }
                    season = (int) JsonUtil.integer (e, "season");
                    episode = (int) JsonUtil.integer (e, "episode");
                    if (season < 0 || episode < 0) {
                        continue;
                    }
                }
                if (!library.db.has_watch_event (type, id, season, episode, watched_at)) {
                    library.db.add_watch_event (type, id, season, episode, watched_at);
                    result.events_added++;
                }
            }
            return t;
        }

        private string format_time (int64 timestamp) {
            return new DateTime.from_unix_utc (timestamp).format_iso8601 ();
        }

        private int64 parse_time (string? s) {
            if (s == null) {
                return 0;
            }
            var dt = new DateTime.from_iso8601 (s, new TimeZone.utc ());
            return dt != null ? dt.to_unix () : 0;
        }
    }
}
