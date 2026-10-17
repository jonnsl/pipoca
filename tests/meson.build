test_library = executable('test-library', 'test-library.vala',
  dependencies: core_dep,
  vala_args: ['--target-glib=2.80'],
)

test('library', test_library,
  env: [
    'XDG_DATA_HOME=' + meson.current_build_dir() / 'test-data',
    'GSETTINGS_SCHEMA_DIR=' + meson.project_build_root() / 'data',
    'GSETTINGS_BACKEND=memory',
  ],
)
