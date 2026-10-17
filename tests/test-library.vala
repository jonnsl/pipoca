using Aperture;

/* Status and progress derivation, against a temporary database (see tests/meson.build) */

Episode ep (int64 show_id, int season, int number, string air_date) {
    var e = new Episode (show_id, season, number);
    e.name = "Episode %d".printf (number);
    e.air_date = air_date;
    return e;
}

Title make_show (int64 id, string status) {
    var lib = Library.get_default ();
    var t = new Title (MediaType.TV, id);
    t.name = "Show %lld".printf (id);
    t.tmdb_status = status;
    // Pretend it's fresh so add() doesn't hit the network
    t.refreshed_at = new DateTime.now_utc ().to_unix ();
    var seasons = new GenericArray<Season> ();
    seasons.add (new Season (id, 0));
    seasons.add (new Season (id, 1));
    seasons.add (new Season (id, 2));
    var specials = new GenericArray<Episode> ();
    specials.add (ep (id, 0, 1, "2019-01-01"));
    var s1 = new GenericArray<Episode> ();
    s1.add (ep (id, 1, 1, "2020-01-01"));
    s1.add (ep (id, 1, 2, "2020-01-08"));
    s1.add (ep (id, 1, 3, "2020-01-15"));
    var s2 = new GenericArray<Episode> ();
    s2.add (ep (id, 2, 1, "2021-01-01"));
    s2.add (ep (id, 2, 2, "2099-01-01"));
    try {
        lib.db.save_seasons (id, seasons);
        lib.db.save_episodes (id, 0, specials);
        lib.db.save_episodes (id, 1, s1);
        lib.db.save_episodes (id, 2, s2);
    } catch (Error e) {
        error (e.message);
    }
    return lib.intern (t);
}

void test_show_progress () {
    var lib = Library.get_default ();
    var show = make_show (100, "Returning Series");
    lib.add (show);
    assert (show.in_library);
    assert (show.status == TitleStatus.PLAN_TO_WATCH);
    assert (show.aired_count == 4);
    assert (show.total_count == 5);
    assert (show.next_episode.season_number == 1 && show.next_episode.episode_number == 1);
    assert (show.upcoming_episode.season_number == 2 && show.upcoming_episode.episode_number == 2);

    var s1 = lib.get_episodes (show, 1);
    var first = new GenericArray<Episode> ();
    first.add (s1[0]);
    lib.set_episodes_watched (show, first, true);
    assert (show.status == TitleStatus.WATCHING);
    assert (show.watched_count == 1);
    assert (show.next_episode.episode_number == 2);

    // Specials don't count towards progress
    lib.set_episodes_watched (show, lib.get_episodes (show, 0), true);
    assert (show.watched_count == 1);

    // Up to S2E1 marks the earlier regular episodes too, but not the unaired one
    var s2 = lib.get_episodes (show, 2);
    var changed = lib.set_episodes_watched (show, lib.get_episodes_up_to (show, s2[0]), true);
    assert (changed.length == 3);
    assert (show.status == TitleStatus.UP_TO_DATE);
    assert (show.next_episode == null);

    // Unwatching one goes back to Watching, and it becomes the next episode
    var one = new GenericArray<Episode> ();
    one.add (lib.get_episodes (show, 1)[1]);
    lib.set_episodes_watched (show, one, false);
    assert (show.status == TitleStatus.WATCHING);
    assert (show.next_episode.season_number == 1 && show.next_episode.episode_number == 2);

    var seasons = lib.get_seasons (show);
    assert (seasons[0].season_number == 1);  // specials last
    assert (seasons[0].aired_count == 3 && seasons[0].watched_count == 2);
    assert (seasons[2].season_number == 0);
}

void test_ended_show () {
    var lib = Library.get_default ();
    var show = make_show (200, "Ended");
    lib.add (show);
    var all = new GenericArray<Episode> ();
    foreach (var s in new int[] { 1, 2 }) {
        foreach (var e in lib.get_episodes (show, s)) {
            all.add (e);
        }
    }
    lib.set_episodes_watched (show, all, true);
    // The 2099 episode can't be watched, so the show is only up to date
    assert (show.status == TitleStatus.UP_TO_DATE);

    // Once every episode has aired and been watched, an ended show is done
    var s2 = lib.get_episodes (show, 2);
    s2[1].air_date = "2021-01-08";
    try {
        lib.db.save_episodes (show.id, 2, s2);
    } catch (Error e) {
        error (e.message);
    }
    var last = new GenericArray<Episode> ();
    last.add (lib.get_episodes (show, 2)[1]);
    lib.set_episodes_watched (show, last, true);
    assert (show.status == TitleStatus.WATCHED);
    assert (show.status.is_done ());
}

void test_movie () {
    var lib = Library.get_default ();
    var movie = new Title (MediaType.MOVIE, 300);
    movie.name = "A Movie";
    movie.refreshed_at = new DateTime.now_utc ().to_unix ();
    movie = lib.intern (movie);

    // Watching something that isn't in the library adds it
    lib.set_movie_watched (movie, true);
    assert (movie.in_library);
    assert (movie.status == TitleStatus.WATCHED);
    assert (movie.last_watched_at > 0);

    lib.set_movie_watched (movie, false);
    assert (movie.status == TitleStatus.PLAN_TO_WATCH);

    var before = lib.titles.get_n_items ();
    lib.remove (movie);
    assert (!movie.in_library);
    assert (movie.status == TitleStatus.NONE);
    assert (lib.titles.get_n_items () == before - 1);

    lib.add (movie);
    assert (movie.in_library && lib.titles.get_n_items () == before);
}

void test_persistence () {
    var path = Path.build_filename (Environment.get_user_data_dir (), "aperture", "library.db");
    try {
        var db = new Database (path);
        var titles = db.load_library ();
        assert (titles.length == 3);
        var show = db.load_title (MediaType.TV, 100);
        assert (show.name == "Show 100" && show.in_library);
    } catch (Error e) {
        error (e.message);
    }
}

void test_from_json () {
    var parser = new Json.Parser ();
    try {
        parser.load_from_data ("""{"media_type": "tv", "id": 95396, "name": "Severance",
            "first_air_date": "2022-02-17", "poster_path": null, "vote_average": 8.4,
            "genres": [{"id": 18, "name": "Drama"}, {"id": 9648, "name": "Mystery"}],
            "episode_run_time": [], "networks": [{"name": "Apple TV+"}]}""");
    } catch (Error e) {
        error (e.message);
    }
    var t = Title.from_json (parser.get_root ().get_object ());
    assert (t.media_type == MediaType.TV && t.id == 95396);
    assert (t.name == "Severance" && t.year == "2022");
    assert (t.poster_path == null);
    assert (t.genres == "Drama, Mystery" && t.networks == "Apple TV+");
    assert (t.describe () == "2022 · TV Show");

    try {
        parser.load_from_data ("""{"media_type": "person", "id": 1}""");
    } catch (Error e) {
        error (e.message);
    }
    assert (Title.from_json (parser.get_root ().get_object ()) == null);
}

Json.Object parse_object (string data) {
    var parser = new Json.Parser ();
    try {
        parser.load_from_data (data);
    } catch (Error e) {
        error (e.message);
    }
    return parser.get_root ().get_object ();
}

void test_export () {
    var lib = Library.get_default ();
    string data;
    try {
        data = LibraryTransfer.export_json (lib);
    } catch (Error e) {
        error (e.message);
    }
    var root = parse_object (data);
    assert (root.get_string_member ("format") == "aperture-library");
    assert (root.get_int_member ("version") == 1);
    var titles = root.get_array_member ("titles");
    assert (titles.get_length () == lib.titles.get_n_items ());

    Json.Object? show = null;
    for (uint i = 0; i < titles.get_length (); i++) {
        var t = titles.get_object_element (i);
        if (t.get_string_member ("media_type") == "tv" && t.get_int_member ("tmdb_id") == 100) {
            show = t;
        }
    }
    assert (show != null);
    assert (show.get_string_member ("name") == "Show 100");
    var watched = show.get_array_member ("watched");
    // S1E1, S0E1 (specials), S1E3, S2E1 from test_show_progress
    assert (watched.get_length () == 4);
    var first = watched.get_object_element (0);
    assert (first.has_member ("season") && first.has_member ("episode") && first.has_member ("watched_at"));
    assert (new DateTime.from_iso8601 (first.get_string_member ("watched_at"), null) != null);

    // Importing our own export changes nothing
    try {
        var result = LibraryTransfer.import_json (lib, data);
        assert (result.titles_added == 0 && result.events_added == 0 && result.titles_skipped == 0);
    } catch (Error e) {
        error (e.message);
    }

    // Removed titles come back with their original date
    var movie = lib.lookup (MediaType.MOVIE, 300);
    var added_at = movie.added_at;
    lib.remove (movie);
    try {
        var result = LibraryTransfer.import_json (lib, data);
        assert (result.titles_added == 1);
    } catch (Error e) {
        error (e.message);
    }
    assert (movie.in_library && movie.added_at == added_at);
}

void test_import () {
    var lib = Library.get_default ();
    var data = """{
        "format": "aperture-library",
        "version": 1,
        "titles": [
            {"media_type": "movie", "tmdb_id": 400, "name": "Imported Movie", "release_date": "1999-03-31",
             "added_at": "2024-01-02T03:04:05Z", "watched": [{"watched_at": "2024-02-01T20:00:00Z"}]},
            {"media_type": "tv", "tmdb_id": 100, "name": "Show 100",
             "watched": [{"season": 1, "episode": 2, "watched_at": "2024-03-01T20:00:00Z"},
                         {"season": 1, "episode": 2, "watched_at": "2024-03-01T20:00:00Z"},
                         {"episode": 3, "watched_at": "2024-03-01T20:00:00Z"},
                         {"season": 1, "episode": 3}]},
            {"media_type": "person", "tmdb_id": 1},
            {"media_type": "movie", "tmdb_id": -5},
            "garbage"
        ]
    }""";
    ImportResult result;
    try {
        result = LibraryTransfer.import_json (lib, data);
    } catch (Error e) {
        error (e.message);
    }
    assert (result.titles_added == 1);
    assert (result.titles_skipped == 3);
    // The movie's event plus one S1E2 event; the duplicate and malformed ones are dropped
    assert (result.events_added == 2);

    var movie = lib.lookup (MediaType.MOVIE, 400);
    assert (movie.in_library && movie.name == "Imported Movie" && movie.year == "1999");
    assert (movie.added_at == new DateTime.utc (2024, 1, 2, 3, 4, 5).to_unix ());
    assert (movie.status == TitleStatus.WATCHED);
    assert (!movie.has_details);

    // S1E2 was the only aired episode left, so the show is caught up
    var show = lib.lookup (MediaType.TV, 100);
    assert (lib.get_episodes (show, 1)[1].watched);
    assert (show.watched_count == show.aired_count);
    assert (show.status == TitleStatus.UP_TO_DATE);
}

void test_import_errors () {
    var lib = Library.get_default ();
    string[] bad = {
        "not json",
        "[]",
        """{"format": "something-else", "version": 1, "titles": []}""",
        """{"format": "aperture-library", "version": 1}""",
    };
    foreach (var data in bad) {
        try {
            LibraryTransfer.import_json (lib, data);
            assert_not_reached ();
        } catch (Error e) {
            // Expected
        }
    }
    try {
        LibraryTransfer.import_json (lib, """{"format": "aperture-library", "version": 99, "titles": []}""");
        assert_not_reached ();
    } catch (TransferError.UNSUPPORTED_VERSION e) {
        // Expected
    } catch (Error e) {
        assert_not_reached ();
    }
}

KodiItem kodi_item (MediaType type, int64 kodi_id, int64 tmdb_id, string title, int playcount, int64 last_played) {
    return new KodiItem () {
        media_type = type,
        kodi_id = kodi_id,
        tmdb_id = tmdb_id,
        title = title,
        year = 2020,
        playcount = playcount,
        last_played = last_played,
        date_added = 1600000000,
    };
}

KodiItem kodi_episode (int64 show_kodi_id, int season, int episode, int playcount, int64 last_played) {
    var e = kodi_item (MediaType.TV, show_kodi_id, 0, "", playcount, last_played);
    e.season = season;
    e.episode = episode;
    return e;
}

void test_kodi_import () {
    var lib = Library.get_default ();
    var movies = new GenericArray<KodiItem> ();
    movies.add (kodi_item (MediaType.MOVIE, 1, 500, "Kodi Movie", 2, 1700000000));
    movies.add (kodi_item (MediaType.MOVIE, 2, 501, "Unwatched Kodi Movie", 0, 1700000000));
    movies.add (kodi_item (MediaType.MOVIE, 3, 0, "Unmatched", 1, 0));
    var shows = new GenericArray<KodiItem> ();
    shows.add (kodi_item (MediaType.TV, 7, 600, "Kodi Show", 0, 0));
    // Already in the library from earlier tests; Kodi's numbering is used as is
    shows.add (kodi_item (MediaType.TV, 8, 100, "Show 100", 0, 0));
    var episodes = new GenericArray<KodiItem> ();
    episodes.add (kodi_episode (7, 1, 1, 1, 1700000100));
    episodes.add (kodi_episode (7, 1, 2, 0, 0));
    episodes.add (kodi_episode (8, 1, 1, 1, 1700000200));  // already watched in Aperture
    episodes.add (kodi_episode (99, 1, 1, 1, 1700000300)); // show Kodi didn't list

    KodiSyncResult r;
    try {
        r = KodiImport.apply (lib, movies, shows, episodes);
    } catch (Error e) {
        error (e.message);
    }
    assert (r.titles_added == 3);
    assert (r.titles_unmatched == 1);
    // Watched movie + the new show's S1E1; Show 100 S1E1 already had an event
    assert (r.events_added == 2);

    var movie = lib.lookup (MediaType.MOVIE, 500);
    assert (movie.in_library && movie.name == "Kodi Movie" && movie.year == "2020");
    assert (movie.added_at == 1600000000);
    assert (movie.status == TitleStatus.WATCHED && movie.last_watched_at == 1700000000);
    assert (lib.lookup (MediaType.MOVIE, 501).status == TitleStatus.PLAN_TO_WATCH);

    try {
        var events = lib.db.load_watch_events (MediaType.TV, 600);
        assert (events.length == 1 && events[0].season_number == 1 && events[0].episode_number == 1);
        assert (events[0].watched_at == 1700000100);
    } catch (Error e) {
        error (e.message);
    }

    // Syncing again changes nothing
    try {
        r = KodiImport.apply (lib, movies, shows, episodes);
    } catch (Error e) {
        error (e.message);
    }
    assert (r.titles_added == 0 && r.events_added == 0);

    // A title the user removed stays removed and gets no new events,
    // even though Kodi still has it as watched
    lib.set_movie_watched (movie, false);
    lib.remove (movie);
    var shows2 = new GenericArray<KodiItem> ();
    try {
        r = KodiImport.apply (lib, movies, shows2, new GenericArray<KodiItem> ());
    } catch (Error e) {
        error (e.message);
    }
    assert (r.titles_added == 0 && r.events_added == 0);
    assert (!movie.in_library);

    // Watching something in Kodi later is picked up by the next sync
    var unwatched = lib.lookup (MediaType.MOVIE, 501);
    movies[1].playcount = 1;
    try {
        r = KodiImport.apply (lib, movies, shows2, new GenericArray<KodiItem> ());
    } catch (Error e) {
        error (e.message);
    }
    assert (r.events_added == 1 && unwatched.status == TitleStatus.WATCHED);
}

void test_kodi_parsing () {
    try {
        assert (KodiClient.make_endpoint ("192.168.1.151:8080") == "http://192.168.1.151:8080/jsonrpc");
        assert (KodiClient.make_endpoint (" http://kodi.local:8080/ ") == "http://kodi.local:8080/jsonrpc");
        assert (KodiClient.make_endpoint ("https://kodi.local/jsonrpc") == "https://kodi.local/jsonrpc");
    } catch (Error e) {
        error (e.message);
    }
    try {
        KodiClient.make_endpoint ("  ");
        assert_not_reached ();
    } catch (Error e) {
        // Expected
    }
    var expected = new DateTime.local (2022, 6, 4, 1, 11, 31).to_unix ();
    assert (KodiClient.parse_time ("2022-06-04 01:11:31") == expected);
    assert (KodiClient.parse_time ("") == 0);
    assert (KodiClient.parse_time (null) == 0);
}

void test_dropped () {
    var lib = Library.get_default ();
    var show = make_show (700, "Returning Series");
    lib.add (show);
    var first = new GenericArray<Episode> ();
    first.add (lib.get_episodes (show, 1)[0]);
    lib.set_episodes_watched (show, first, true);
    assert (show.status == TitleStatus.WATCHING);

    lib.set_dropped (show, true);
    assert (show.is_dropped && show.status == TitleStatus.DROPPED);
    assert (!show.status.in_watchlist () && !show.status.is_done ());
    // Progress is still known, for showing where it was left off
    assert (show.watched_count == 1 && show.next_episode != null);
    try {
        assert (lib.db.load_title (MediaType.TV, 700).dropped_at == show.dropped_at);
    } catch (Error e) {
        error (e.message);
    }

    // Exported and imported along with the title
    string data;
    try {
        data = LibraryTransfer.export_json (lib);
    } catch (Error e) {
        error (e.message);
    }
    var dropped_at = show.dropped_at;
    lib.remove (show);
    assert (!show.is_dropped);
    try {
        LibraryTransfer.import_json (lib, data);
    } catch (Error e) {
        error (e.message);
    }
    assert (show.in_library && show.dropped_at == dropped_at && show.status == TitleStatus.DROPPED);

    // Watching more picks it back up
    var second = new GenericArray<Episode> ();
    second.add (lib.get_episodes (show, 1)[1]);
    lib.set_episodes_watched (show, second, true);
    assert (!show.is_dropped && show.status == TitleStatus.WATCHING);

    // Unwatching doesn't
    lib.set_dropped (show, true);
    lib.set_episodes_watched (show, second, false);
    assert (show.status == TitleStatus.DROPPED);

    lib.set_dropped (show, false);
    assert (show.dropped_at == 0 && show.status == TitleStatus.WATCHING);
}

void test_releases () {
    var lib = Library.get_default ();
    var today = Utils.today ();
    var show = make_show (800, "Returning Series");
    var s3 = new GenericArray<Episode> ();
    s3.add (ep (800, 3, 2, Utils.days_from_today (1)));
    s3.add (ep (800, 3, 1, today));
    try {
        lib.db.save_episodes (800, 3, s3);
    } catch (Error e) {
        error (e.message);
    }
    lib.add (show);

    var movie = new Title (MediaType.MOVIE, 801);
    movie.name = "Upcoming Movie";
    movie.release_date = Utils.days_from_today (3);
    movie.refreshed_at = new DateTime.now_utc ().to_unix ();
    lib.add (lib.intern (movie));

    var releases = lib.get_releases (today, Utils.days_from_today (7));
    var mine = new GenericArray<Release> ();
    foreach (var r in releases) {
        if (r.title == show || r.title == movie) {
            mine.add (r);
        }
    }
    assert (mine.length == 3);
    assert (mine[0].episode.episode_number == 1 && mine[0].date == today);
    assert (mine[1].episode.episode_number == 2);
    assert (mine[2].title == movie && mine[2].episode == null);
    // Ordered by date across titles
    for (var i = 1; i < releases.length; i++) {
        assert (releases[i - 1].date <= releases[i].date);
    }

    // Open-ended includes the far future; past episodes are left out
    var count_2099 = 0;
    foreach (var r in lib.get_releases (today)) {
        assert (r.date >= today);
        if (r.title == show && r.date == "2099-01-01") {
            count_2099++;
        }
    }
    assert (count_2099 == 1);

    // Watched movies and dropped shows are left out
    lib.set_movie_watched (movie, true);
    lib.set_dropped (show, true);
    foreach (var r in lib.get_releases (today)) {
        assert (r.title != show && r.title != movie);
    }
    lib.set_dropped (show, false);
    lib.set_movie_watched (movie, false);
}

void test_new_badges () {
    var lib = Library.get_default ();
    var show = make_show (900, "Returning Series");
    lib.add (show);
    var movie = new Title (MediaType.MOVIE, 901);
    movie.name = "Released Movie";
    movie.release_date = "2020-06-01";
    movie.refreshed_at = new DateTime.now_utc ().to_unix ();
    lib.add (lib.intern (movie));
    assert (!show.has_new && !movie.has_new);

    // S2E1 aired 2021-01-01; the S2E2 in 2099 hasn't aired, so it isn't new
    lib.new_since = "2020-12-31";
    assert (show.has_new);
    assert (!movie.has_new);
    lib.new_since = "2021-01-01";
    assert (!show.has_new);

    // Watching what's new clears the badge
    lib.new_since = "2020-12-31";
    lib.set_episodes_watched (show, lib.get_episodes (show, 2), true);
    assert (!show.has_new);

    // So does seeing the title, until the next session
    lib.new_since = "2019-12-31";
    assert (show.has_new && movie.has_new);
    lib.mark_seen (show);
    assert (!show.has_new && movie.has_new);
    lib.new_since = "2019-12-31";
    assert (show.has_new);

    // Watched movies and dropped titles aren't new
    lib.set_movie_watched (movie, true);
    assert (!movie.has_new);
    lib.set_dropped (show, true);
    assert (!show.has_new);

    lib.new_since = null;
    assert (!show.has_new);
}

int main (string[] args) {
    Test.init (ref args);
    // Start from an empty database
    var path = Path.build_filename (Environment.get_user_data_dir (), "aperture", "library.db");
    foreach (var suffix in new string[] { "", "-wal", "-shm" }) {
        FileUtils.remove (path + suffix);
    }
    Test.add_func ("/title/from-json", test_from_json);
    Test.add_func ("/library/show-progress", test_show_progress);
    Test.add_func ("/library/ended-show", test_ended_show);
    Test.add_func ("/library/movie", test_movie);
    Test.add_func ("/library/persistence", test_persistence);
    Test.add_func ("/transfer/export", test_export);
    Test.add_func ("/transfer/import", test_import);
    Test.add_func ("/transfer/import-errors", test_import_errors);
    Test.add_func ("/kodi/import", test_kodi_import);
    Test.add_func ("/kodi/parsing", test_kodi_parsing);
    Test.add_func ("/library/dropped", test_dropped);
    Test.add_func ("/library/releases", test_releases);
    Test.add_func ("/library/new-badges", test_new_badges);
    return Test.run ();
}
