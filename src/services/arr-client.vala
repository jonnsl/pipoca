namespace Pipoca {
    public errordomain ArrError {
        NOT_CONFIGURED,
        UNAUTHORIZED,
        CERTIFICATE,
        HTTP,
        INVALID_RESPONSE,
    }

    /* A movie in Radarr or a series in Sonarr */
    public class ArrItem : Object {
        /* Radarr's or Sonarr's own id */
        public int64 arr_id;
        public int64 tmdb_id;
        /* Sonarr only, for series it can't match to TMDB */
        public int64 tvdb_id;
        public string title = "";
        public int year;
        public int64 date_added;
    }

    public class ArrQualityProfile : Object {
        public int64 id;
        public string name = "";
    }

    /**
     * Talks to the v3 API that Radarr and Sonarr share. Besides the API key,
     * it can log in to a reverse proxy with HTTP Basic auth and accept
     * self-signed certificates.
     */
    public abstract class ArrClient : Object {
        /* "Radarr" or "Sonarr", for messages */
        public string service { get; private set; }

        private Soup.Session session;
        private string base_url;
        private string api_key;
        private string? authorization;
        private bool accept_any_certificate;

        protected ArrClient (string service, string address, string? api_key, string? username, string? password,
                             bool accept_any_certificate) throws Error {
            this.service = service;
            base_url = make_base_url (service, address);
            if (api_key == null || api_key == "") {
                throw new ArrError.NOT_CONFIGURED (_("No %s API key configured").printf (service));
            }
            this.api_key = api_key;
            if (username != null && username != "") {
                var credentials = "%s:%s".printf (username, password ?? "");
                authorization = "Basic " + Base64.encode (credentials.data);
            }
            this.accept_any_certificate = accept_any_certificate;
            session = new Soup.Session () { timeout = 60 };
        }

        /* Accepts "host:port" or a URL, with the URL base if there's one; returns ".../api/v3" */
        public static string make_base_url (string service, string address) throws Error {
            var a = address.strip ();
            if (a == "") {
                throw new ArrError.NOT_CONFIGURED (_("No %s address configured").printf (service));
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
                throw new ArrError.NOT_CONFIGURED (_("Invalid %s address").printf (service));
            }
            return a;
        }

        protected Error invalid_response () {
            return new ArrError.INVALID_RESPONSE (_("Invalid response from %s").printf (service));
        }

        protected async Json.Node request (string method, string path, Json.Node? body,
                                           Cancellable? cancellable) throws Error {
            var msg = new Soup.Message (method, base_url + path);
            if (msg == null) {
                throw new ArrError.NOT_CONFIGURED (_("Invalid %s address").printf (service));
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
                throw new ArrError.CERTIFICATE (_("%s’s certificate isn’t trusted").printf (service));
            }
            if (msg.status_code == 401) {
                // A proxy in front asks for a password; Radarr and Sonarr themselves only check the key
                if (msg.response_headers.get_one ("WWW-Authenticate") != null) {
                    throw new ArrError.UNAUTHORIZED (_("The server rejected the username or password"));
                }
                throw new ArrError.UNAUTHORIZED (_("%s rejected the API key").printf (service));
            }
            if (msg.status_code < 200 || msg.status_code >= 300) {
                throw new ArrError.HTTP ("HTTP %u: %s", msg.status_code, msg.reason_phrase);
            }
            // Some calls answer with nothing
            if (bytes.get_size () == 0) {
                return new Json.Node (Json.NodeType.NULL);
            }

            var parser = new Json.Parser ();
            try {
                parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            } catch (Error e) {
                throw invalid_response ();
            }
            var root = parser.get_root ();
            if (root == null) {
                throw invalid_response ();
            }
            return root;
        }

        protected async Json.Array get_array (string path, Cancellable? cancellable) throws Error {
            var root = yield request ("GET", path, null, cancellable);
            if (root.get_node_type () != Json.NodeType.ARRAY) {
                throw invalid_response ();
            }
            return root.dup_array ();
        }

        public async GenericArray<ArrQualityProfile> get_quality_profiles (Cancellable? cancellable = null) throws Error {
            var arr = yield get_array ("/qualityprofile", cancellable);
            var profiles = new GenericArray<ArrQualityProfile> ();
            arr.foreach_element ((a, i, node) => {
                if (node.get_node_type () == Json.NodeType.OBJECT) {
                    var o = node.get_object ();
                    profiles.add (new ArrQualityProfile () {
                        id = JsonUtil.integer (o, "id"),
                        name = JsonUtil.str (o, "name") ?? "",
                    });
                }
            });
            return profiles;
        }

        /* Paths of the folders the library is kept in */
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

        /* The movies or series in the library */
        public abstract async GenericArray<ArrItem> get_items (Cancellable? cancellable = null) throws Error;

        public static GenericArray<ArrItem> parse_items (Json.Array arr) {
            var items = new GenericArray<ArrItem> ();
            arr.foreach_element ((a, i, node) => {
                if (node.get_node_type () != Json.NodeType.OBJECT) {
                    return;
                }
                var o = node.get_object ();
                items.add (new ArrItem () {
                    arr_id = JsonUtil.integer (o, "id"),
                    tmdb_id = JsonUtil.integer (o, "tmdbId"),
                    tvdb_id = JsonUtil.integer (o, "tvdbId"),
                    title = JsonUtil.str (o, "title") ?? "",
                    year = (int) JsonUtil.integer (o, "year"),
                    date_added = parse_time (JsonUtil.str (o, "added")),
                });
            });
            return items;
        }

        /* UTC ISO 8601 times; year 1 means unset */
        public static int64 parse_time (string? s) {
            if (s == null || s.has_prefix ("0001-")) {
                return 0;
            }
            var dt = new DateTime.from_iso8601 (s, new TimeZone.utc ());
            return dt != null ? dt.to_unix () : 0;
        }
    }
}
