namespace Aperture {
    /**
     * Downloads TMDB images, keeps them on disk by size and path, and decodes
     * them off the main thread. Recently used textures stay in memory.
     */
    public class ImageCache : Object {
        private const string BASE_URL = "https://image.tmdb.org/t/p/";
        private const uint MEMORY_LIMIT = 150;

        private static ImageCache? instance;

        private class DecodeJob {
            public string path;
            public Gdk.Texture? texture;
            public Error? error;
            public SourceFunc callback;
        }

        private class Waiter {
            public SourceFunc callback;
            public Gdk.Texture? texture;

            public Waiter (owned SourceFunc callback) {
                this.callback = (owned) callback;
            }
        }

        private Soup.Session session;
        private string dir;
        private ThreadPool<DecodeJob> decoder;
        private HashTable<string, Gdk.Texture> memory = new HashTable<string, Gdk.Texture> (str_hash, str_equal);
        private Queue<string> memory_order = new Queue<string> ();
        private HashTable<string, GenericArray<Waiter>> pending = new HashTable<string, GenericArray<Waiter>> (str_hash, str_equal);

        public static ImageCache get_default () {
            if (instance == null) {
                instance = new ImageCache ();
            }
            return instance;
        }

        construct {
            session = (Soup.Session) Object.new (typeof (Soup.Session),
                                                 "user-agent", "Aperture/%s ".printf (Config.VERSION),
                                                 "max-conns-per-host", 6);
            dir = Path.build_filename (Environment.get_user_cache_dir (), "aperture", "images");
            try {
                decoder = new ThreadPool<DecodeJob>.with_owned_data ((job) => {
                    try {
                        job.texture = Gdk.Texture.from_filename (job.path);
                    } catch (Error e) {
                        job.error = e;
                    }
                    Idle.add ((owned) job.callback);
                }, 4, false);
            } catch (ThreadError e) {
                error ("Can't create image decoder threads: %s", e.message);
            }
        }

        public string get_directory () {
            return dir;
        }

        private string get_file_path (string tmdb_path, string size) {
            return Path.build_filename (dir, size, tmdb_path.replace ("/", ""));
        }

        /* The image's file if it's already on disk, without downloading it */
        public File? get_cached_file (string tmdb_path, string size) {
            var file = File.new_for_path (get_file_path (tmdb_path, size));
            return file.query_exists () ? file : null;
        }

        /**
         * Loads a TMDB image. @size is a TMDB size such as "w342".
         * Returns null if the image can't be loaded or @cancellable was cancelled.
         *
         * Concurrent loads of the same image share one download; cancelling
         * only stops this caller from waiting, since others may need it.
         */
        public async Gdk.Texture? load (string tmdb_path, string size, Cancellable? cancellable = null) {
            var key = size + tmdb_path;
            var cached = memory[key];
            if (cached != null) {
                return cached;
            }

            var waiters = pending[key];
            if (waiters != null) {
                // Take the texture from the download itself: by the time this
                // resumes, other loads may have already evicted it from memory
                var waiter = new Waiter (load.callback);
                waiters.add (waiter);
                yield;
                return cancellable != null && cancellable.is_cancelled () ? null : waiter.texture;
            }
            pending[key] = new GenericArray<Waiter> ();

            var texture = yield fetch (key, get_file_path (tmdb_path, size), BASE_URL + size + tmdb_path);
            if (texture != null) {
                remember (key, texture);
            }
            foreach (var w in pending[key]) {
                w.texture = texture;
                Idle.add ((owned) w.callback);
            }
            pending.remove (key);
            return cancellable != null && cancellable.is_cancelled () ? null : texture;
        }

        private async Gdk.Texture? fetch (string key, string file_path, string url) {
            var file = File.new_for_path (file_path);
            try {
                if (!file.query_exists ()) {
                    yield download (url, file);
                }
                var job = new DecodeJob () { path = file_path, callback = fetch.callback };
                decoder.add (job);
                yield;
                if (job.error != null) {
                    // A corrupt file would fail forever; drop it so it's downloaded again
                    file.delete_async.begin (Priority.LOW, null);
                    throw job.error;
                }
                return job.texture;
            } catch (Error e) {
                debug ("Can't load image %s: %s", key, e.message);
                return null;
            }
        }

        private async void download (string url, File file) throws Error {
            var msg = new Soup.Message ("GET", url);
            var bytes = yield session.send_and_read_async (msg, Priority.LOW, null);
            if (msg.status_code != 200) {
                throw new IOError.FAILED ("HTTP %u", msg.status_code);
            }
            DirUtils.create_with_parents (file.get_parent ().get_path (), 0755);
            // Write to a temporary file first so a crash never leaves a truncated image behind
            var tmp = File.new_for_path (file.get_path () + ".part");
            yield tmp.replace_contents_bytes_async (bytes, null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
            tmp.move (file, FileCopyFlags.OVERWRITE);
        }

        private void remember (string key, Gdk.Texture texture) {
            if (!memory.contains (key)) {
                memory_order.push_tail (key);
            }
            memory[key] = texture;
            while (memory_order.length > MEMORY_LIMIT) {
                memory.remove (memory_order.pop_head ());
            }
        }

        /* Size of the disk cache in bytes */
        public async int64 get_size () {
            int64 total = 0;
            SourceFunc callback = get_size.callback;
            new Thread<void> ("image-cache-size", () => {
                total = du (File.new_for_path (dir));
                Idle.add ((owned) callback);
            });
            yield;
            return total;
        }

        private static int64 du (File dir) {
            int64 total = 0;
            try {
                var e = dir.enumerate_children ("standard::name,standard::type,standard::size", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? info;
                while ((info = e.next_file ()) != null) {
                    if (info.get_file_type () == FileType.DIRECTORY) {
                        total += du (dir.get_child (info.get_name ()));
                    } else {
                        total += info.get_size ();
                    }
                }
            } catch (Error e) {
                // Missing directory: nothing cached yet
            }
            return total;
        }

        public async void clear () {
            memory.remove_all ();
            memory_order.clear ();
            SourceFunc callback = clear.callback;
            new Thread<void> ("image-cache-clear", () => {
                rm_rf (File.new_for_path (dir));
                Idle.add ((owned) callback);
            });
            yield;
        }

        private static void rm_rf (File file) {
            try {
                var e = file.enumerate_children ("standard::name,standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? info;
                while ((info = e.next_file ()) != null) {
                    var child = file.get_child (info.get_name ());
                    if (info.get_file_type () == FileType.DIRECTORY) {
                        rm_rf (child);
                    } else {
                        child.delete ();
                    }
                }
                file.delete ();
            } catch (Error e) {
                debug ("Can't remove %s: %s", file.get_path (), e.message);
            }
        }
    }
}
