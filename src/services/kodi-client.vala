namespace Pipoca {
    public errordomain KodiError {
        NOT_CONFIGURED,
        UNAUTHORIZED,
        HTTP,
        RPC,
    }

    /* A movie, show or episode from Kodi's video library */
    public class KodiItem : Object {
        public MediaType media_type;
        /* Kodi's own id; for episodes, the id of their show */
        public int64 kodi_id;
        public string title = "";
        public int year;
        public int season = -1;
        public int episode = -1;
        public int playcount;
        public int64 last_played;
        public int64 date_added;
        public int64 tmdb_id;
        public string? imdb_id;
        public string? tvdb_id;

        public bool watched {
            get { return playcount > 0; }
        }
    }

    /**
     * Reads Kodi's video library over JSON-RPC (HTTP). Read-only: it never
     * sends anything that changes Kodi.
     */
    public class KodiClient : Object {
        private Soup.Session session;
        private string endpoint;
        private string? authorization;

        public KodiClient (string address, string? username, string? password) throws Error {
            endpoint = make_endpoint (address);
            if (username != null && username != "") {
                var credentials = "%s:%s".printf (username, password ?? "");
                authorization = "Basic " + Base64.encode (credentials.data);
            }
            session = new Soup.Session () { timeout = 60 };
        }

        /* Accepts "host:port", "http://host:port/" or a full ".../jsonrpc" URL */
        public static string make_endpoint (string address) throws Error {
            var a = address.strip ();
            if (a == "") {
                throw new KodiError.NOT_CONFIGURED (_("No Kodi address configured"));
            }
            if (!a.has_prefix ("http://") && !a.has_prefix ("https://")) {
                a = "http://" + a;
            }
            while (a.has_suffix ("/")) {
                a = a.substring (0, a.length - 1);
            }
            if (!a.has_suffix ("/jsonrpc")) {
                a += "/jsonrpc";
            }
            if (Uri.peek_scheme (a) == null) {
                throw new KodiError.NOT_CONFIGURED (_("Invalid Kodi address"));
            }
            return a;
        }

        private async Json.Object call (string method, Json.Node? params, Cancellable? cancellable) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("jsonrpc").add_string_value ("2.0");
            b.set_member_name ("id").add_int_value (1);
            b.set_member_name ("method").add_string_value (method);
            if (params != null) {
                b.set_member_name ("params").add_value (params);
            }
            b.end_object ();
            var body = Json.to_string (b.get_root (), false);

            var msg = new Soup.Message ("POST", endpoint);
            if (msg == null) {
                throw new KodiError.NOT_CONFIGURED (_("Invalid Kodi address"));
            }
            if (authorization != null) {
                msg.request_headers.append ("Authorization", authorization);
            }
            msg.set_request_body_from_bytes ("application/json", new Bytes (body.data));
            var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, cancellable);
            if (msg.status_code == 401) {
                throw new KodiError.UNAUTHORIZED (_("Kodi rejected the username or password"));
            }
            if (msg.status_code != 200) {
                throw new KodiError.HTTP ("HTTP %u: %s", msg.status_code, msg.reason_phrase);
            }

            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                throw new KodiError.RPC (_("Invalid response from Kodi"));
            }
            var obj = root.get_object ();
            var error = JsonUtil.object (obj, "error");
            if (error != null) {
                throw new KodiError.RPC ("%s", JsonUtil.str (error, "message") ?? _("Kodi returned an error"));
            }
            var result = JsonUtil.object (obj, "result");
            if (result == null) {
                throw new KodiError.RPC (_("Invalid response from Kodi"));
            }
            return result;
        }

        private static Json.Node property_list (string[] names) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("properties").begin_array ();
            foreach (var n in names) {
                b.add_string_value (n);
            }
            b.end_array ();
            b.end_object ();
            return b.get_root ();
        }

        public async GenericArray<KodiItem> get_movies (Cancellable? cancellable = null) throws Error {
            var result = yield call ("VideoLibrary.GetMovies",
                                     property_list ({ "title", "year", "playcount", "lastplayed", "dateadded", "uniqueid" }),
                                     cancellable);
            return parse_items (result, "movies", "movieid", MediaType.MOVIE);
        }

        public async GenericArray<KodiItem> get_shows (Cancellable? cancellable = null) throws Error {
            var result = yield call ("VideoLibrary.GetTVShows",
                                     property_list ({ "title", "year", "playcount", "lastplayed", "dateadded", "uniqueid" }),
                                     cancellable);
            return parse_items (result, "tvshows", "tvshowid", MediaType.TV);
        }

        /* Every episode in the library; kodi_id is the episode's show */
        public async GenericArray<KodiItem> get_episodes (Cancellable? cancellable = null) throws Error {
            var result = yield call ("VideoLibrary.GetEpisodes",
                                     property_list ({ "tvshowid", "season", "episode", "playcount", "lastplayed" }),
                                     cancellable);
            return parse_items (result, "episodes", "tvshowid", MediaType.TV);
        }

        private static GenericArray<KodiItem> parse_items (Json.Object result, string member, string id_member, MediaType type) {
            var items = new GenericArray<KodiItem> ();
            var arr = JsonUtil.array (result, member);
            if (arr == null) {
                // Kodi leaves the member out when the library is empty
                return items;
            }
            arr.foreach_element ((a, i, node) => {
                if (node.get_node_type () != Json.NodeType.OBJECT) {
                    return;
                }
                var o = node.get_object ();
                var item = new KodiItem () {
                    media_type = type,
                    kodi_id = JsonUtil.integer (o, id_member),
                    title = JsonUtil.str (o, "title") ?? JsonUtil.str (o, "label") ?? "",
                    year = (int) JsonUtil.integer (o, "year"),
                    playcount = (int) JsonUtil.integer (o, "playcount"),
                    last_played = parse_time (JsonUtil.str (o, "lastplayed")),
                    date_added = parse_time (JsonUtil.str (o, "dateadded")),
                };
                if (o.has_member ("season")) {
                    item.season = (int) JsonUtil.integer (o, "season");
                    item.episode = (int) JsonUtil.integer (o, "episode");
                }
                var ids = JsonUtil.object (o, "uniqueid");
                if (ids != null) {
                    item.tmdb_id = int64.parse (JsonUtil.str (ids, "tmdb") ?? "0");
                    item.imdb_id = JsonUtil.str (ids, "imdb");
                    item.tvdb_id = JsonUtil.str (ids, "tvdb");
                }
                items.add (item);
            });
            return items;
        }

        /* Kodi reports "YYYY-MM-DD HH:MM:SS" in its local time; empty when unset */
        public static int64 parse_time (string? s) {
            if (s == null || s.length < 19) {
                return 0;
            }
            var dt = new DateTime.from_iso8601 (s.replace (" ", "T"), new TimeZone.local ());
            return dt != null ? dt.to_unix () : 0;
        }
    }
}
