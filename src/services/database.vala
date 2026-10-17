namespace Aperture {
    public errordomain DatabaseError {
        FAILED,
    }

    /**
     * SQLite storage for titles, seasons, episodes and watch events.
     *
     * Watch events for movies use -1 as season and episode number.
     */
    public class Database : Object {
        private const int SCHEMA_VERSION = 2;

        private Sqlite.Database db;

        public Database (string path) throws Error {
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            if (Sqlite.Database.open_v2 (path, out db) != Sqlite.OK) {
                throw new DatabaseError.FAILED ("Can't open %s: %s", path, db.errmsg ());
            }
            exec ("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;");
            migrate ();
        }

        private void migrate () throws Error {
            var stmt = prepare ("PRAGMA user_version");
            stmt.step ();
            var version = stmt.column_int (0);
            if (version >= SCHEMA_VERSION) {
                return;
            }
            begin ();
            try {
                if (version < 1) {
                    create_v1 ();
                }
                if (version < 2) {
                    // Titles a Kodi sync has seen, so removed ones aren't added back
                    exec ("""
                        CREATE TABLE kodi_seen (
                            media_type INTEGER NOT NULL,
                            tmdb_id INTEGER NOT NULL,
                            PRIMARY KEY (media_type, tmdb_id)
                        );
                    """);
                }
                exec ("PRAGMA user_version = %d".printf (SCHEMA_VERSION));
                commit ();
            } catch (Error e) {
                rollback ();
                throw e;
            }
        }

        private void create_v1 () throws Error {
            exec ("""
                CREATE TABLE titles (
                    media_type INTEGER NOT NULL,
                    tmdb_id INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    original_name TEXT,
                    original_language TEXT,
                    overview TEXT,
                    poster_path TEXT,
                    backdrop_path TEXT,
                    release_date TEXT,
                    runtime INTEGER NOT NULL DEFAULT 0,
                    genres TEXT,
                    vote_average REAL NOT NULL DEFAULT 0,
                    tmdb_status TEXT,
                    creators TEXT,
                    networks TEXT,
                    number_of_seasons INTEGER NOT NULL DEFAULT 0,
                    number_of_episodes INTEGER NOT NULL DEFAULT 0,
                    in_library INTEGER NOT NULL DEFAULT 0,
                    added_at INTEGER NOT NULL DEFAULT 0,
                    refreshed_at INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (media_type, tmdb_id)
                );
                CREATE TABLE seasons (
                    show_id INTEGER NOT NULL,
                    season_number INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    overview TEXT,
                    poster_path TEXT,
                    air_date TEXT,
                    episode_count INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (show_id, season_number)
                );
                CREATE TABLE episodes (
                    show_id INTEGER NOT NULL,
                    season_number INTEGER NOT NULL,
                    episode_number INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    overview TEXT,
                    still_path TEXT,
                    air_date TEXT,
                    runtime INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (show_id, season_number, episode_number)
                );
                CREATE TABLE watch_events (
                    id INTEGER PRIMARY KEY,
                    media_type INTEGER NOT NULL,
                    tmdb_id INTEGER NOT NULL,
                    season_number INTEGER NOT NULL DEFAULT -1,
                    episode_number INTEGER NOT NULL DEFAULT -1,
                    watched_at INTEGER NOT NULL
                );
                CREATE INDEX watch_events_title ON watch_events (media_type, tmdb_id, season_number, episode_number);
            """);
        }

        public void exec (string sql) throws Error {
            string errmsg;
            if (db.exec (sql, null, out errmsg) != Sqlite.OK) {
                throw new DatabaseError.FAILED ("%s", errmsg);
            }
        }

        public Sqlite.Statement prepare (string sql) throws Error {
            Sqlite.Statement stmt;
            if (db.prepare_v2 (sql, -1, out stmt) != Sqlite.OK) {
                throw new DatabaseError.FAILED ("%s", db.errmsg ());
            }
            return stmt;
        }

        private void run (Sqlite.Statement stmt) throws Error {
            if (stmt.step () != Sqlite.DONE) {
                throw new DatabaseError.FAILED ("%s", db.errmsg ());
            }
        }

        public void begin () throws Error {
            exec ("BEGIN");
        }

        public void commit () throws Error {
            exec ("COMMIT");
        }

        public void rollback () {
            try {
                exec ("ROLLBACK");
            } catch (Error e) {
                warning ("Rollback failed: %s", e.message);
            }
        }

        private static void bind_str (Sqlite.Statement stmt, int index, string? value) {
            if (value == null) {
                stmt.bind_null (index);
            } else {
                stmt.bind_text (index, value);
            }
        }

        private static string? dup_str (Sqlite.Statement stmt, int col) {
            unowned string? s = stmt.column_text (col);
            return s;
        }

        /* ---- Titles ---- */

        private const string TITLE_COLUMNS = """
            media_type, tmdb_id, name, original_name, original_language, overview,
            poster_path, backdrop_path, release_date, runtime, genres, vote_average,
            tmdb_status, creators, networks, number_of_seasons, number_of_episodes,
            in_library, added_at, refreshed_at""";

        private static Title title_from_row (Sqlite.Statement stmt) {
            var t = new Title ((MediaType) stmt.column_int (0), stmt.column_int64 (1));
            t.name = dup_str (stmt, 2) ?? "";
            t.original_name = dup_str (stmt, 3);
            t.original_language = dup_str (stmt, 4);
            t.overview = dup_str (stmt, 5);
            t.poster_path = dup_str (stmt, 6);
            t.backdrop_path = dup_str (stmt, 7);
            t.release_date = dup_str (stmt, 8);
            t.runtime = stmt.column_int (9);
            t.genres = dup_str (stmt, 10);
            t.vote_average = stmt.column_double (11);
            t.tmdb_status = dup_str (stmt, 12);
            t.creators = dup_str (stmt, 13);
            t.networks = dup_str (stmt, 14);
            t.number_of_seasons = stmt.column_int (15);
            t.number_of_episodes = stmt.column_int (16);
            t.in_library = stmt.column_int (17) != 0;
            t.added_at = stmt.column_int64 (18);
            t.refreshed_at = stmt.column_int64 (19);
            return t;
        }

        public GenericArray<Title> load_library () throws Error {
            var stmt = prepare ("SELECT %s FROM titles WHERE in_library = 1".printf (TITLE_COLUMNS));
            var result = new GenericArray<Title> ();
            while (stmt.step () == Sqlite.ROW) {
                result.add (title_from_row (stmt));
            }
            return result;
        }

        public Title? load_title (MediaType type, int64 id) throws Error {
            var stmt = prepare ("SELECT %s FROM titles WHERE media_type = ?1 AND tmdb_id = ?2".printf (TITLE_COLUMNS));
            stmt.bind_int (1, type);
            stmt.bind_int64 (2, id);
            return stmt.step () == Sqlite.ROW ? title_from_row (stmt) : null;
        }

        public void save_title (Title t) throws Error {
            var stmt = prepare ("INSERT OR REPLACE INTO titles (%s) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)".printf (TITLE_COLUMNS));
            stmt.bind_int (1, t.media_type);
            stmt.bind_int64 (2, t.id);
            stmt.bind_text (3, t.name);
            bind_str (stmt, 4, t.original_name);
            bind_str (stmt, 5, t.original_language);
            bind_str (stmt, 6, t.overview);
            bind_str (stmt, 7, t.poster_path);
            bind_str (stmt, 8, t.backdrop_path);
            bind_str (stmt, 9, t.release_date);
            stmt.bind_int (10, t.runtime);
            bind_str (stmt, 11, t.genres);
            stmt.bind_double (12, t.vote_average);
            bind_str (stmt, 13, t.tmdb_status);
            bind_str (stmt, 14, t.creators);
            bind_str (stmt, 15, t.networks);
            stmt.bind_int (16, t.number_of_seasons);
            stmt.bind_int (17, t.number_of_episodes);
            stmt.bind_int (18, t.in_library ? 1 : 0);
            stmt.bind_int64 (19, t.added_at);
            stmt.bind_int64 (20, t.refreshed_at);
            run (stmt);
        }

        /* ---- Seasons & episodes ---- */

        public void save_seasons (int64 show_id, GenericArray<Season> seasons) throws Error {
            var del = prepare ("DELETE FROM seasons WHERE show_id = ?1");
            del.bind_int64 (1, show_id);
            run (del);
            var stmt = prepare ("INSERT INTO seasons (show_id, season_number, name, overview, poster_path, air_date, episode_count) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)");
            foreach (var s in seasons) {
                stmt.reset ();
                stmt.bind_int64 (1, show_id);
                stmt.bind_int (2, s.season_number);
                stmt.bind_text (3, s.name);
                bind_str (stmt, 4, s.overview);
                bind_str (stmt, 5, s.poster_path);
                bind_str (stmt, 6, s.air_date);
                stmt.bind_int (7, s.episode_count);
                run (stmt);
            }
        }

        public void save_episodes (int64 show_id, int season_number, GenericArray<Episode> episodes) throws Error {
            var del = prepare ("DELETE FROM episodes WHERE show_id = ?1 AND season_number = ?2");
            del.bind_int64 (1, show_id);
            del.bind_int (2, season_number);
            run (del);
            var stmt = prepare ("INSERT OR REPLACE INTO episodes (show_id, season_number, episode_number, name, overview, still_path, air_date, runtime) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)");
            foreach (var e in episodes) {
                stmt.reset ();
                stmt.bind_int64 (1, show_id);
                stmt.bind_int (2, season_number);
                stmt.bind_int (3, e.episode_number);
                stmt.bind_text (4, e.name);
                bind_str (stmt, 5, e.overview);
                bind_str (stmt, 6, e.still_path);
                bind_str (stmt, 7, e.air_date);
                stmt.bind_int (8, e.runtime);
                run (stmt);
            }
        }

        /* Number of stored episodes per season */
        public HashTable<int, int> count_episodes (int64 show_id) throws Error {
            var stmt = prepare ("SELECT season_number, COUNT(*) FROM episodes WHERE show_id = ?1 GROUP BY season_number");
            stmt.bind_int64 (1, show_id);
            var result = new HashTable<int, int> (direct_hash, direct_equal);
            while (stmt.step () == Sqlite.ROW) {
                result[stmt.column_int (0)] = stmt.column_int (1);
            }
            return result;
        }

        private const string WATCHED_EXPR = """
            EXISTS (SELECT 1 FROM watch_events w WHERE w.media_type = 1 AND w.tmdb_id = e.show_id
                    AND w.season_number = e.season_number AND w.episode_number = e.episode_number)""";

        private const string AIRED_EXPR = "(e.air_date IS NOT NULL AND e.air_date <> '' AND e.air_date <= ?2)";

        public GenericArray<Season> load_seasons (int64 show_id) throws Error {
            var stmt = prepare ("""
                SELECT s.season_number, s.name, s.overview, s.poster_path, s.air_date, s.episode_count,
                    (SELECT COUNT(*) FROM episodes e WHERE e.show_id = s.show_id AND e.season_number = s.season_number AND %s),
                    (SELECT COUNT(*) FROM episodes e WHERE e.show_id = s.show_id AND e.season_number = s.season_number AND %s AND %s)
                FROM seasons s WHERE s.show_id = ?1
                ORDER BY s.season_number = 0, s.season_number
            """.printf (AIRED_EXPR, AIRED_EXPR, WATCHED_EXPR));
            stmt.bind_int64 (1, show_id);
            stmt.bind_text (2, Utils.today ());
            var result = new GenericArray<Season> ();
            while (stmt.step () == Sqlite.ROW) {
                var s = new Season (show_id, stmt.column_int (0));
                s.name = dup_str (stmt, 1) ?? "";
                s.overview = dup_str (stmt, 2);
                s.poster_path = dup_str (stmt, 3);
                s.air_date = dup_str (stmt, 4);
                s.episode_count = stmt.column_int (5);
                s.aired_count = stmt.column_int (6);
                s.watched_count = stmt.column_int (7);
                result.add (s);
            }
            return result;
        }

        private const string EPISODE_COLUMNS = "e.season_number, e.episode_number, e.name, e.overview, e.still_path, e.air_date, e.runtime";

        private static Episode episode_from_row (int64 show_id, Sqlite.Statement stmt) {
            var e = new Episode (show_id, stmt.column_int (0), stmt.column_int (1));
            e.name = dup_str (stmt, 2) ?? "";
            e.overview = dup_str (stmt, 3);
            e.still_path = dup_str (stmt, 4);
            e.air_date = dup_str (stmt, 5);
            e.runtime = stmt.column_int (6);
            e.watched = stmt.column_int (7) != 0;
            return e;
        }

        /* Parameters: ?1 show id, ?2 today, ?3 a, ?4 b. Unused ones fail to bind harmlessly. */
        private GenericArray<Episode> query_episodes (int64 show_id, string where, int a = 0, int b = 0, int limit = -1) throws Error {
            var stmt = prepare ("SELECT %s, %s FROM episodes e WHERE e.show_id = ?1 AND %s ORDER BY e.season_number, e.episode_number LIMIT %d"
                                .printf (EPISODE_COLUMNS, WATCHED_EXPR, where, limit));
            stmt.bind_int64 (1, show_id);
            stmt.bind_text (2, Utils.today ());
            stmt.bind_int (3, a);
            stmt.bind_int (4, b);
            var result = new GenericArray<Episode> ();
            while (stmt.step () == Sqlite.ROW) {
                result.add (episode_from_row (show_id, stmt));
            }
            return result;
        }

        public GenericArray<Episode> load_episodes (int64 show_id, int season_number) throws Error {
            return query_episodes (show_id, "e.season_number = ?3", season_number);
        }

        /* Aired episodes of the same season-kind (regular or specials) up to and including the given one */
        public GenericArray<Episode> load_aired_episodes_up_to (int64 show_id, int season_number, int episode_number) throws Error {
            var where = season_number == 0
                ? "%s AND e.season_number = 0 AND e.episode_number <= ?4"
                : "%s AND e.season_number > 0 AND (e.season_number < ?3 OR (e.season_number = ?3 AND e.episode_number <= ?4))";
            return query_episodes (show_id, where.printf (AIRED_EXPR), season_number, episode_number);
        }

        /* ---- Watch events ---- */

        public void add_watch_event (MediaType type, int64 id, int season, int episode, int64 watched_at) throws Error {
            var stmt = prepare ("INSERT INTO watch_events (media_type, tmdb_id, season_number, episode_number, watched_at) VALUES (?1, ?2, ?3, ?4, ?5)");
            stmt.bind_int (1, type);
            stmt.bind_int64 (2, id);
            stmt.bind_int (3, season);
            stmt.bind_int (4, episode);
            stmt.bind_int64 (5, watched_at);
            run (stmt);
        }

        public void remove_watch_events (MediaType type, int64 id, int season, int episode) throws Error {
            var stmt = prepare ("DELETE FROM watch_events WHERE media_type = ?1 AND tmdb_id = ?2 AND season_number = ?3 AND episode_number = ?4");
            stmt.bind_int (1, type);
            stmt.bind_int64 (2, id);
            stmt.bind_int (3, season);
            stmt.bind_int (4, episode);
            run (stmt);
        }

        public struct WatchEvent {
            public int season_number;
            public int episode_number;
            public int64 watched_at;
        }

        public WatchEvent[] load_watch_events (MediaType type, int64 id) throws Error {
            var stmt = prepare ("""
                SELECT season_number, episode_number, watched_at FROM watch_events
                WHERE media_type = ?1 AND tmdb_id = ?2
                ORDER BY watched_at, season_number, episode_number""");
            stmt.bind_int (1, type);
            stmt.bind_int64 (2, id);
            WatchEvent[] result = {};
            while (stmt.step () == Sqlite.ROW) {
                result += WatchEvent () {
                    season_number = stmt.column_int (0),
                    episode_number = stmt.column_int (1),
                    watched_at = stmt.column_int64 (2),
                };
            }
            return result;
        }

        public bool has_watch_event (MediaType type, int64 id, int season, int episode, int64 watched_at) throws Error {
            var stmt = prepare ("""
                SELECT 1 FROM watch_events WHERE media_type = ?1 AND tmdb_id = ?2
                AND season_number = ?3 AND episode_number = ?4 AND watched_at = ?5 LIMIT 1""");
            stmt.bind_int (1, type);
            stmt.bind_int64 (2, id);
            stmt.bind_int (3, season);
            stmt.bind_int (4, episode);
            stmt.bind_int64 (5, watched_at);
            return stmt.step () == Sqlite.ROW;
        }

        /* Whether the movie or episode has been watched at all */
        public bool has_watch_events (MediaType type, int64 id, int season, int episode) throws Error {
            var stmt = prepare ("""
                SELECT 1 FROM watch_events WHERE media_type = ?1 AND tmdb_id = ?2
                AND season_number = ?3 AND episode_number = ?4 LIMIT 1""");
            stmt.bind_int (1, type);
            stmt.bind_int64 (2, id);
            stmt.bind_int (3, season);
            stmt.bind_int (4, episode);
            return stmt.step () == Sqlite.ROW;
        }

        /* Records that a Kodi sync has seen a title; returns false if it already had */
        public bool mark_kodi_seen (MediaType type, int64 id) throws Error {
            var stmt = prepare ("INSERT OR IGNORE INTO kodi_seen (media_type, tmdb_id) VALUES (?1, ?2)");
            stmt.bind_int (1, type);
            stmt.bind_int64 (2, id);
            run (stmt);
            return db.changes () > 0;
        }

        public int64 last_watched_at (MediaType type, int64 id) throws Error {
            var stmt = prepare ("SELECT MAX(watched_at) FROM watch_events WHERE media_type = ?1 AND tmdb_id = ?2");
            stmt.bind_int (1, type);
            stmt.bind_int64 (2, id);
            return stmt.step () == Sqlite.ROW ? stmt.column_int64 (0) : 0;
        }

        public bool movie_watched (int64 id) throws Error {
            var stmt = prepare ("SELECT 1 FROM watch_events WHERE media_type = 0 AND tmdb_id = ?1 LIMIT 1");
            stmt.bind_int64 (1, id);
            return stmt.step () == Sqlite.ROW;
        }

        /* Counts of regular (non-special) episodes: total, aired, and aired & watched */
        public void count_show_progress (int64 show_id, out int total, out int aired, out int watched) throws Error {
            var stmt = prepare ("""
                SELECT COUNT(*), COALESCE(SUM(%s), 0), COALESCE(SUM(%s AND %s), 0)
                FROM episodes e WHERE e.show_id = ?1 AND e.season_number > 0
            """.printf (AIRED_EXPR, AIRED_EXPR, WATCHED_EXPR));
            stmt.bind_int64 (1, show_id);
            stmt.bind_text (2, Utils.today ());
            stmt.step ();
            total = stmt.column_int (0);
            aired = stmt.column_int (1);
            watched = stmt.column_int (2);
        }

        /**
         * The first aired, unwatched regular episode after the furthest one
         * watched, falling back to the first unwatched one overall.
         */
        public Episode? find_next_episode (int64 show_id) throws Error {
            var after = query_episodes (show_id, """
                %s AND e.season_number > 0 AND NOT %s
                AND e.season_number * 100000 + e.episode_number > COALESCE(
                    (SELECT MAX(w.season_number * 100000 + w.episode_number) FROM watch_events w
                     WHERE w.media_type = 1 AND w.tmdb_id = ?1 AND w.season_number > 0), 0)
            """.printf (AIRED_EXPR, WATCHED_EXPR), 0, 0, 1);
            if (after.length > 0) {
                return after[0];
            }
            var any = query_episodes (show_id, "%s AND e.season_number > 0 AND NOT %s".printf (AIRED_EXPR, WATCHED_EXPR), 0, 0, 1);
            return any.length > 0 ? any[0] : null;
        }

        /* The next regular episode that hasn't aired yet */
        public Episode? find_upcoming_episode (int64 show_id) throws Error {
            var stmt = prepare ("""
                SELECT %s, 0 FROM episodes e
                WHERE e.show_id = ?1 AND e.season_number > 0 AND e.air_date > ?2
                ORDER BY e.air_date, e.season_number, e.episode_number LIMIT 1
            """.printf (EPISODE_COLUMNS));
            stmt.bind_int64 (1, show_id);
            stmt.bind_text (2, Utils.today ());
            return stmt.step () == Sqlite.ROW ? episode_from_row (show_id, stmt) : null;
        }
    }
}
