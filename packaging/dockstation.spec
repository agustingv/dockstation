# Built in place from a checkout by packaging/build-rpm.sh, which passes the version.
%{!?app_version:%global app_version 0}
%global debug_package %{nil}

Name:           dockstation
Version:        %{app_version}
Release:        1
Summary:        Manage and create Docker Compose projects
License:        GPL-3.0-or-later
URL:            https://agustingv.github.io/dockstation/

BuildRequires:  appstream
BuildRequires:  desktop-file-utils
BuildRequires:  gcc
BuildRequires:  gettext
BuildRequires:  meson
BuildRequires:  ninja-build
BuildRequires:  vala
BuildRequires:  pkgconfig(gio-2.0) >= 2.76
BuildRequires:  pkgconfig(gtk4) >= 4.14
BuildRequires:  pkgconfig(gtksourceview-5) >= 5.10
BuildRequires:  pkgconfig(libadwaita-1) >= 1.6
BuildRequires:  pkgconfig(libportal-gtk4) >= 0.7

# GTK aborts at startup without libGLESv2, which it opens at run time, so rpm cannot
# detect it. By library and not by package: it is libglvnd-gles in Fedora, libglvnd in openSUSE.
Requires:       libGLESv2.so.2()(64bit)

Recommends:     (moby-engine or docker-ce or docker)
Recommends:     (docker-compose or docker-compose-plugin)

%description
DockStation keeps all your Docker Compose projects in one place. Start, stop
and restart services, follow their logs, edit the configuration and create new
projects from ready-made templates.

%build
%meson
%meson_build

%install
%meson_install
install -Dpm 644 packaging/dockstation.repo %{buildroot}%{_sysconfdir}/yum.repos.d/dockstation.repo
install -Dpm 644 packaging/RPM-GPG-KEY-dockstation %{buildroot}%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-dockstation
%find_lang %{name}

%check
%meson_test

%files -f %{name}.lang
%{_bindir}/dockstation
%{_datadir}/applications/io.github.agustingv.dockstation.desktop
%{_datadir}/icons/hicolor/scalable/apps/io.github.agustingv.dockstation.svg
%{_datadir}/metainfo/io.github.agustingv.dockstation.metainfo.xml
%config(noreplace) %{_sysconfdir}/yum.repos.d/dockstation.repo
%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-dockstation
