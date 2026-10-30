desktop_file = i18n.merge_file(
  input: configure_file(
    input: 'dockstation.desktop.in',
    output: app_id + '.desktop.in',
    configuration: { 'APP_ID': app_id },
  ),
  output: app_id + '.desktop',
  type: 'desktop',
  po_dir: '../po',
  install: true,
  install_dir: get_option('datadir') / 'applications',
)

desktop_utils = find_program('desktop-file-validate', required: false)
if desktop_utils.found()
  test('validate-desktop', desktop_utils, args: [desktop_file])
endif

metainfo_file = i18n.merge_file(
  input: configure_file(
    input: 'dockstation.metainfo.xml.in',
    output: app_id + '.metainfo.xml.in',
    configuration: { 'APP_ID': app_id },
  ),
  output: app_id + '.metainfo.xml',
  po_dir: '../po',
  install: true,
  install_dir: get_option('datadir') / 'metainfo',
)

appstreamcli = find_program('appstreamcli', required: false)
if appstreamcli.found()
  test('validate-metainfo', appstreamcli,
    args: ['validate', '--no-net', '--explain', metainfo_file],
  )
endif

dockstation_resources = gnome.compile_resources('dockstation-resources',
  'dockstation.gresource.xml',
  c_name: 'dockstation',
)

install_data('icons/hicolor/scalable/apps/' + app_id + '.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
)
