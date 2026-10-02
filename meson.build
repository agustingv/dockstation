project('dockstation', ['c', 'vala'],
  version: '0.0.1-alpha',
  meson_version: '>= 1.0.0',
  license: 'GPL-3.0-or-later',
)

i18n = import('i18n')
gnome = import('gnome')

app_id = 'io.github.agustingv.dockstation'

conf = configuration_data()
conf.set_quoted('APP_ID', app_id)
conf.set_quoted('PACKAGE_VERSION', meson.project_version())
conf.set_quoted('GETTEXT_PACKAGE', meson.project_name())
conf.set_quoted('LOCALEDIR', get_option('prefix') / get_option('localedir'))
configure_file(output: 'config.h', configuration: conf)

add_project_arguments(
  '-I' + meson.project_build_root(),
  '-include', 'config.h',
  # Vala-generated C is noisy; keep the build output readable.
  '-w',
  '-Wno-error=incompatible-pointer-types',
  '-Wno-error=int-conversion',
  language: 'c',
)

subdir('data')
subdir('src')
subdir('po')

gnome.post_install(
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)
