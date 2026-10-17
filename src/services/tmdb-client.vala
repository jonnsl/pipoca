namespace Aperture {
    public errordomain TmdbError {
        NO_API_KEY,
        HTTP,
        PARSE,
    }

    public enum SearchFilter {
        ALL,
        MOVIES,
        SHOWS,
    }

    /**
     * Minimal async client for the TMDB v3 API.
     *
     * Accepts either a v3 API key or a v4 read access token. Requests go
     * through a small queue so we stay well below TMDB's rate limit.
     */
    public class TmdbClient : Object {
        private const string BASE_URL = "https://api.themoviedb.org/3";
        private const int MAX_ACTIVE = 8;
        private const int MAX_ATTEMPTS = 3;

        private class Waiter {
            public SourceFunc callback;

            public Waiter (owned SourceFunc callback) {
                this.callback = (owned) callback;
            }
        }

        private Soup.Session session;
        private Settings settings;
        private int active = 0;
        private Queue<Waiter> waiting = new Queue<Waiter> ();

        public string language { get; set; }

        construct {
            session = (Soup.Session) Object.new (typeof (Soup.Session),
                                                 "user-agent", "Aperture/%s ".printf (Config.VERSION),
                                                 "max-conns-per-host", MAX_ACTIVE,
                                                 "timeout", 30);
            settings = new Settings (Config.APPLICATION_ID);
            language = detect_language ();
        }

        /* TMDB wants "pt-BR" style tags; derive one from the locale */
        private static string detect_language () {
            foreach (var name in Intl.get_language_names ()) {
                if (name == "C" || name == "POSIX") {
                    continue;
                }
                var tag = name.split (".")[0].split ("@")[0];
                var parts = tag.split ("_");
                if (parts.length == 2 && parts[0].length == 2) {
                    return "%s-%s".printf (parts[0], parts[1]);
                }
                if (parts[0].length == 2) {
                    return parts[0];
                }
            }
            return "en-US";
        }

        private string get_api_key () {
            if (settings.get_boolean ("use-custom-api-key")) {
                var custom = settings.get_string ("custom-api-key").strip ();
                if (custom != "") {
                    return custom;
                }
            }
            return Config.TMDB_API_KEY;
        }

        private async void acquire () {
            if (active < MAX_ACTIVE) {
                active++;
                return;
            }
            waiting.push_tail (new Waiter (acquire.callback));
            yield;
        }

        private void release () {
            var next = waiting.pop_head ();
            if (next != null) {
                // Hand our slot over to the next request
                Idle.add ((owned) next.callback);
            } else {
                active--;
            }
        }

        public async Json.Object get_object (string path, string[] query = {}, Cancellable? cancellable = null) throws Error {
            var key = get_api_key ();
            if (key == "") {
                throw new TmdbError.NO_API_KEY (_("No TMDB API key configured"));
            }
            // v4 read access tokens are JWTs; anything else is a v3 key
            var is_token = key.has_prefix ("eyJ");

            var uri = new StringBuilder (BASE_URL);
            uri.append (path);
            uri.append_printf ("?language=%s", Uri.escape_string (language));
            if (!is_token) {
                uri.append_printf ("&api_key=%s", Uri.escape_string (key));
            }
            foreach (var q in query) {
                uri.append_c ('&');
                uri.append (q);
            }

            yield acquire ();
            try {
                for (var attempt = 1;; attempt++) {
                    var msg = new Soup.Message ("GET", uri.str);
                    msg.request_headers.append ("Accept", "application/json");
                    if (is_token) {
                        msg.request_headers.append ("Authorization", "Bearer " + key);
                    }
                    var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, cancellable);

                    if (msg.status_code == 429 && attempt < MAX_ATTEMPTS) {
                        var retry_after = int.parse (msg.response_headers.get_one ("Retry-After") ?? "1");
                        Timeout.add_seconds (uint.max (1, retry_after), get_object.callback);
                        yield;
                        continue;
                    }

                    var parser = new Json.Parser ();
                    try {
                        parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
                    } catch (Error e) {
                        if (msg.status_code != 200) {
                            throw new TmdbError.HTTP ("HTTP %u: %s", msg.status_code, msg.reason_phrase);
                        }
                        throw new TmdbError.PARSE ("Invalid response from TMDB: %s", e.message);
                    }
                    var root = parser.get_root ();
                    if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                        throw new TmdbError.PARSE ("Invalid response from TMDB");
                    }
                    var obj = root.get_object ();
                    if (msg.status_code != 200) {
                        var status = JsonUtil.str (obj, "status_message") ?? msg.reason_phrase;
                        throw new TmdbError.HTTP ("HTTP %u: %s", msg.status_code, status);
                    }
                    return obj;
                }
            } finally {
                release ();
            }
        }

        public async GenericArray<Title> search (string text, SearchFilter filter, Cancellable? cancellable = null) throws Error {
            string path;
            MediaType? fallback = null;
            switch (filter) {
            case SearchFilter.MOVIES:
                path = "/search/movie";
                fallback = MediaType.MOVIE;
                break;
            case SearchFilter.SHOWS:
                path = "/search/tv";
                fallback = MediaType.TV;
                break;
            default:
                path = "/search/multi";
                break;
            }
            var obj = yield get_object (path, { "query=" + Uri.escape_string (text), "include_adult=false" }, cancellable);
            var results = new GenericArray<Title> ();
            var arr = JsonUtil.array (obj, "results");
            if (arr != null) {
                arr.foreach_element ((a, i, node) => {
                    if (node.get_node_type () != Json.NodeType.OBJECT) {
                        return;
                    }
                    // /search/multi also returns people; Title.from_json skips them
                    var t = Title.from_json (node.get_object (), fallback);
                    if (t != null && t.id != 0) {
                        results.add (t);
                    }
                });
            }
            return results;
        }

        public async Json.Object get_details (MediaType type, int64 id, Cancellable? cancellable = null) throws Error {
            return yield get_object ("/%s/%lld".printf (type.to_api_string (), id), {}, cancellable);
        }

        /**
         * Fetches several seasons of a show at once with append_to_response
         * (at most 20 per request) and returns the "season/N" objects.
         */
        public async GenericArray<Json.Object> get_seasons (int64 show_id, int[] season_numbers, Cancellable? cancellable = null) throws Error {
            var result = new GenericArray<Json.Object> ();
            for (var start = 0; start < season_numbers.length; start += 20) {
                string[] parts = {};
                for (var i = start; i < season_numbers.length && i < start + 20; i++) {
                    parts += "season/%d".printf (season_numbers[i]);
                }
                var obj = yield get_object ("/tv/%lld".printf (show_id),
                                            { "append_to_response=" + string.joinv (",", parts) },
                                            cancellable);
                foreach (var part in parts) {
                    var season = JsonUtil.object (obj, part);
                    if (season != null) {
                        result.add (season);
                    }
                }
            }
            return result;
        }
    }
}
