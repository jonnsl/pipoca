blueprints = custom_target('blueprints',
  input: files(
    'dialogs/preferences-dialog.blp',
    'dialogs/search-dialog.blp',
    'pages/details-page.blp',
    'pages/library-view.blp',
    'pages/season-page.blp',
    'shortcuts-dialog.blp',
    'widgets/episode-row.blp',
    'widgets/poster-card.blp',
    'window.blp',
  ),
  output: '.',
  command: [
    find_program('blueprint-compiler'),
    'batch-compile', '@OUTPUT@', '@CURRENT_SOURCE_DIR@', '@INPUT@',
  ],
)

resources = gnome.compile_resources('aperture-resources',
  'aperture.gresource.xml',
  c_name: 'aperture',
  dependencies: blueprints,
)

deps = [
  dependency('gtk4', version: '>= 4.18'),
  dependency('libadwaita-1', version: '>= 1.8'),
  dependency('libsoup-3.0'),
  dependency('libsecret-1'),
  dependency('json-glib-1.0'),
  dependency('sqlite3'),
  meson.get_compiler('vala').find_library('config', dirs: meson.current_source_dir()),
]

# Models and services, without UI, shared with the tests
core_lib = static_library('aperture-core',
  files(
    'models/episode.vala',
    'models/season.vala',
    'models/title.vala',
    'services/database.vala',
    'services/image-cache.vala',
    'services/kodi-client.vala',
    'services/kodi-sync.vala',
    'services/library-transfer.vala',
    'services/library.vala',
    'services/tmdb-client.vala',
    'utils.vala',
  ),
  dependencies: deps,
  include_directories: config_inc,
  vala_args: ['--target-glib=2.80'],
)
core_dep = declare_dependency(
  link_with: core_lib,
  dependencies: deps,
  include_directories: [config_inc, include_directories('.')],
)

sources = files(
  'application.vala',
  'dialogs/preferences-dialog.vala',
  'dialogs/search-dialog.vala',
  'main.vala',
  'pages/details-page.vala',
  'pages/library-view.vala',
  'pages/season-page.vala',
  'title-actions.vala',
  'widgets/episode-row.vala',
  'widgets/poster-card.vala',
  'widgets/poster.vala',
  'window.vala',
)

executable('aperture', sources, resources,
  dependencies: [deps, core_dep],
  include_directories: config_inc,
  vala_args: [
    '--target-glib=2.80',
    '--gresourcesdir=' + meson.current_build_dir(),
  ],
  install: true,
)
