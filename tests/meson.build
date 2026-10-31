dockstation_tests = executable('dockstation-tests',
  files('tests.vala'), dockstation_core_sources, dockstation_resources,
  dependencies: dockstation_deps,
  vala_args: ['--target-glib=2.76'],
)

test('unit', dockstation_tests,
  # Only the built-in services, whatever is in the home folder of whoever runs this.
  env: ['XDG_DATA_HOME=/nonexistent'],
  args: ['--tap'],
  protocol: 'tap',
)
