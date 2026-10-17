blueprints = custom_target('blueprints',
  input: files(
    'shortcuts-dialog.blp',
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

sources = files(
  'application.vala',
  'main.vala',
  'window.vala',
)

deps = [
  dependency('gtk4', version: '>= 4.18'),
  dependency('libadwaita-1', version: '>= 1.8'),
  dependency('libsoup-3.0'),
  dependency('json-glib-1.0'),
  dependency('sqlite3'),
  meson.get_compiler('vala').find_library('config', dirs: meson.current_source_dir()),
]

executable('aperture', sources, resources,
  dependencies: deps,
  include_directories: config_inc,
  vala_args: [
    '--target-glib=2.80',
    '--gresourcesdir=' + meson.current_build_dir(),
  ],
  install: true,
)
