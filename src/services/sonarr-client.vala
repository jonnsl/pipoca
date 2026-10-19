namespace Pipoca {
    /* An episode of a series in Sonarr */
    public struct SonarrEpisode {
        public int64 id;
        public int season;
        public int episode;
        public bool monitored;
    }

    public class SonarrClient : ArrClient {
        public SonarrClient (string address, string? api_key, string? username, string? password,
                             bool accept_any_certificate) throws Error {
            base ("Sonarr", address, api_key, username, password, accept_any_certificate);
        }

        public override async GenericArray<ArrItem> get_items (Cancellable? cancellable = null) throws Error {
            return parse_items (yield get_array ("/series", cancellable));
        }

        /**
         * Adds a series with all its episodes monitored, without starting a
         * search. Returns Sonarr's id for it.
         */
        public async int64 add_series (int64 tmdb_id, int64 quality_profile_id, string root_folder,
                                       Cancellable? cancellable = null) throws Error {
            // Sonarr wants the whole series resource, which its lookup gives us
            var found = yield get_array ("/series/lookup?term=tmdb:%lld".printf (tmdb_id), cancellable);
            if (found.get_length () == 0 || found.get_element (0).get_node_type () != Json.NodeType.OBJECT) {
                throw new ArrError.INVALID_RESPONSE (_("Sonarr can’t find this show"));
            }
            var series = found.get_element (0);
            var o = series.get_object ();
            o.set_int_member ("qualityProfileId", quality_profile_id);
            o.set_string_member ("rootFolderPath", root_folder);
            o.set_boolean_member ("monitored", true);
            o.set_boolean_member ("seasonFolder", true);
            o.set_string_member ("monitorNewItems", "all");
            var options = new Json.Object ();
            options.set_string_member ("monitor", "all");
            options.set_boolean_member ("searchForMissingEpisodes", false);
            options.set_boolean_member ("searchForCutoffUnmetEpisodes", false);
            o.set_object_member ("addOptions", options);
            var added = yield request ("POST", "/series", series, cancellable);
            if (added.get_node_type () != Json.NodeType.OBJECT) {
                throw invalid_response ();
            }
            return JsonUtil.integer (added.get_object (), "id");
        }

        /* Empty until Sonarr has fetched a newly added series */
        public async SonarrEpisode[] get_episodes (int64 series_id, Cancellable? cancellable = null) throws Error {
            var arr = yield get_array ("/episode?seriesId=%lld".printf (series_id), cancellable);
            SonarrEpisode[] episodes = {};
            arr.foreach_element ((a, i, node) => {
                if (node.get_node_type () != Json.NodeType.OBJECT) {
                    return;
                }
                var o = node.get_object ();
                var monitored = o.get_member ("monitored");
                episodes += SonarrEpisode () {
                    id = JsonUtil.integer (o, "id"),
                    season = (int) JsonUtil.integer (o, "seasonNumber"),
                    episode = (int) JsonUtil.integer (o, "episodeNumber"),
                    monitored = monitored != null && monitored.get_value_type () == typeof (bool)
                                && monitored.get_boolean (),
                };
            });
            return episodes;
        }

        /**
         * Whether Sonarr is still fetching the series. When it's done with a
         * newly added one, it applies the add's monitoring to every episode,
         * so episodes changed before then are changed back.
         */
        public async bool refreshing (int64 series_id, Cancellable? cancellable = null) throws Error {
            var arr = yield get_array ("/command", cancellable);
            var found = false;
            arr.foreach_element ((a, i, node) => {
                if (node.get_node_type () != Json.NodeType.OBJECT) {
                    return;
                }
                var o = node.get_object ();
                var status = JsonUtil.str (o, "status");
                var body = JsonUtil.object (o, "body");
                if (JsonUtil.str (o, "name") != "RefreshSeries" || body == null
                    || (status != "queued" && status != "started")) {
                    return;
                }
                if (JsonUtil.integer (body, "seriesId") == series_id) {
                    found = true;
                }
                var ids = JsonUtil.array (body, "seriesIds");
                if (ids != null) {
                    ids.foreach_element ((b, j, id) => {
                        if (id.get_value_type () == typeof (int64) && id.get_int () == series_id) {
                            found = true;
                        }
                    });
                }
            });
            return found;
        }

        public async void set_monitored (int64[] episode_ids, bool monitored, Cancellable? cancellable = null) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("episodeIds").begin_array ();
            foreach (var id in episode_ids) {
                b.add_int_value (id);
            }
            b.end_array ();
            b.set_member_name ("monitored").add_boolean_value (monitored);
            b.end_object ();
            yield request ("PUT", "/episode/monitor", b.get_root (), cancellable);
        }
    }
}
