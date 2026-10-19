namespace Pipoca {
    public errordomain RadarrError {
        NOT_CONFIGURED,
        UNAUTHORIZED,
        CERTIFICATE,
        HTTP,
        INVALID_RESPONSE,
    }

    /* A movie in Radarr's library */
    public class RadarrMovie : Object {
        public int64 tmdb_id;
        public string title = "";
        public int year;
        public int64 date_added;
    }

    public class RadarrQualityProfile : Object {
        public int64 id;
        public string name = "";
    }

    /**
     * Talks to Radarr's v3 API. Besides the API key, it can log in to a
     * reverse proxy with HTTP Basic auth and accept self-signed certificates.
     */
    public class RadarrClient : Object {
        private Soup.Session session;
        private string base_url;
        private string api_key;
        private string? authorization;
        private bool accept_any_certificate;

        public RadarrClient (string address, string? api_key, string? username, string? password,
                             bool accept_any_certificate) throws Error {
            base_url = make_base_url (address);
            if (api_key == null || api_key == "") {
                throw new RadarrError.NOT_CONFIGURED (_("No Radarr API key configured"));
            }
            this.api_key = api_key;
            if (username != null && username != "") {
                var credentials = "%s:%s".printf (username, password ?? "");
                authorization = "Basic " + Base64.encode (credentials.data);
            }
            this.accept_any_certificate = accept_any_certificate;
            session = new Soup.Session () { timeout = 60 };
        }

        /* Accepts "host:port" or a URL, with Radarr's URL base if it has one; returns ".../api/v3" */
        public static string make_base_url (string address) throws Error {
            var a = address.strip ();
            if (a == "") {
                throw new RadarrError.NOT_CONFIGURED (_("No Radarr address configured"));
            }
            if (!a.has_prefix ("http://") && !a.has_prefix ("https://")) {
                a = "http://" + a;
            }
            while (a.has_suffix ("/")) {
                a = a.substring (0, a.length - 1);
            }
            if (!a.has_suffix ("/api/v3")) {
                a += "/api/v3";
            }
            if (Uri.peek_scheme (a) == null) {
                throw new RadarrError.NOT_CONFIGURED (_("Invalid Radarr address"));
            }
            return a;
        }

        private async Json.Node request (string method, string path, Json.Node? body,
                                         Cancellable? cancellable) throws Error {
            var msg = new Soup.Message (method, base_url + path);
            if (msg == null) {
                throw new RadarrError.NOT_CONFIGURED (_("Invalid Radarr address"));
            }
            msg.request_headers.append ("X-Api-Key", api_key);
            msg.request_headers.append ("Accept", "application/json");
            if (authorization != null) {
                msg.request_headers.append ("Authorization", authorization);
            }
            if (accept_any_certificate) {
                msg.accept_certificate.connect (() => true);
            }
            if (body != null) {
                msg.set_request_body_from_bytes ("application/json", new Bytes (Json.to_string (body, false).data));
            }

            Bytes bytes;
            try {
                bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, cancellable);
            } catch (TlsError.BAD_CERTIFICATE e) {
                throw new RadarrError.CERTIFICATE (_("Radarr’s certificate isn’t trusted"));
            }
            if (msg.status_code == 401) {
                // A proxy in front of Radarr asks for a password; Radarr itself only checks the key
                if (msg.response_headers.get_one ("WWW-Authenticate") != null) {
                    throw new RadarrError.UNAUTHORIZED (_("The server rejected the username or password"));
                }
                throw new RadarrError.UNAUTHORIZED (_("Radarr rejected the API key"));
            }
            if (msg.status_code < 200 || msg.status_code >= 300) {
                throw new RadarrError.HTTP ("HTTP %u: %s", msg.status_code, msg.reason_phrase);
            }

            var parser = new Json.Parser ();
            try {
                parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            } catch (Error e) {
                throw new RadarrError.INVALID_RESPONSE (_("Invalid response from Radarr"));
            }
            var root = parser.get_root ();
            if (root == null) {
                throw new RadarrError.INVALID_RESPONSE (_("Invalid response from Radarr"));
            }
            return root;
        }

        private async Json.Array get_array (string path, Cancellable? cancellable) throws Error {
            var root = yield request ("GET", path, null, cancellable);
            if (root.get_node_type () != Json.NodeType.ARRAY) {
                throw new RadarrError.INVALID_RESPONSE (_("Invalid response from Radarr"));
            }
            return root.dup_array ();
        }

        public async GenericArray<RadarrMovie> get_movies (Cancellable? cancellable = null) throws Error {
            var arr = yield get_array ("/movie", cancellable);
            return parse_movies (arr);
        }

        public static GenericArray<RadarrMovie> parse_movies (Json.Array arr) {
            var movies = new GenericArray<RadarrMovie> ();
            arr.foreach_element ((a, i, node) => {
                if (node.get_node_type () != Json.NodeType.OBJECT) {
                    return;
                }
                var o = node.get_object ();
                movies.add (new RadarrMovie () {
                    tmdb_id = JsonUtil.integer (o, "tmdbId"),
                    title = JsonUtil.str (o, "title") ?? "",
                    year = (int) JsonUtil.integer (o, "year"),
                    date_added = parse_time (JsonUtil.str (o, "added")),
                });
            });
            return movies;
        }

        public async GenericArray<RadarrQualityProfile> get_quality_profiles (Cancellable? cancellable = null) throws Error {
            var arr = yield get_array ("/qualityprofile", cancellable);
            var profiles = new GenericArray<RadarrQualityProfile> ();
            arr.foreach_element ((a, i, node) => {
                if (node.get_node_type () == Json.NodeType.OBJECT) {
                    var o = node.get_object ();
                    profiles.add (new RadarrQualityProfile () {
                        id = JsonUtil.integer (o, "id"),
                        name = JsonUtil.str (o, "name") ?? "",
                    });
                }
            });
            return profiles;
        }

        /* Paths of the folders Radarr keeps movies in */
        public async string[] get_root_folders (Cancellable? cancellable = null) throws Error {
            var arr = yield get_array ("/rootfolder", cancellable);
            string[] paths = {};
            arr.foreach_element ((a, i, node) => {
                if (node.get_node_type () == Json.NodeType.OBJECT) {
                    var path = JsonUtil.str (node.get_object (), "path");
                    if (path != null) {
                        paths += path;
                    }
                }
            });
            return paths;
        }

        /**
         * Adds a movie, monitored, without starting a search: Radarr picks up a
         * release through its regular RSS checks.
         */
        public async void add_movie (int64 tmdb_id, int64 quality_profile_id, string root_folder,
                                     Cancellable? cancellable = null) throws Error {
            // Radarr wants the whole movie resource, which its lookup gives us
            var movie = yield request ("GET", "/movie/lookup/tmdb?tmdbId=%lld".printf (tmdb_id), null, cancellable);
            if (movie.get_node_type () != Json.NodeType.OBJECT) {
                throw new RadarrError.INVALID_RESPONSE (_("Invalid response from Radarr"));
            }
            var o = movie.get_object ();
            o.set_int_member ("qualityProfileId", quality_profile_id);
            o.set_string_member ("rootFolderPath", root_folder);
            o.set_boolean_member ("monitored", true);
            o.set_string_member ("minimumAvailability", "released");
            var options = new Json.Object ();
            options.set_boolean_member ("searchForMovie", false);
            o.set_object_member ("addOptions", options);
            yield request ("POST", "/movie", movie, cancellable);
        }

        /* Radarr reports UTC ISO 8601 times; it uses year 1 for unset */
        public static int64 parse_time (string? s) {
            if (s == null || s.has_prefix ("0001-")) {
                return 0;
            }
            var dt = new DateTime.from_iso8601 (s, new TimeZone.utc ());
            return dt != null ? dt.to_unix () : 0;
        }
    }
}
