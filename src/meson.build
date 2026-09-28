dockstation_sources = files(
  'config.vapi',
  'main.vala',
  'application.vala',
  'window.vala',
  'utils.vala',
  'docker.vala',
  'project.vala',
  'project-store.vala',
  'project-row.vala',
  'project-view.vala',
  'service-row.vala',
  'log-view.vala',
  'templates.vala',
  'new-project-dialog.vala',
  'resources.vala',
  'resources-view.vala',
  'settings.vala',
  'database-init.vala',
)

dockstation_deps = [
  dependency('gio-2.0', version: '>= 2.76'),
  dependency('gtk4', version: '>= 4.14'),
  dependency('libadwaita-1', version: '>= 1.6'),
  meson.get_compiler('vala').find_library('posix'),
]

executable('dockstation', dockstation_sources,
  dependencies: dockstation_deps,
  vala_args: ['--target-glib=2.76'],
  install: true,
)
