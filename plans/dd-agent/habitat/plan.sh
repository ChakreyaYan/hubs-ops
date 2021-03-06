pkg_name=dd-agent
pkg_origin=mozillareality
pkg_maintainer="Mozilla Mixed Reality <mixreality@mozilla.com>"

pkg_version="0.1.0"
pkg_description="The Datadog Agent"
pkg_license=("BSD-3-Clause")
pkg_upstream_url="https://github.com/datadog/dd-agent"
pkg_build_deps=(core/curl core/sed core/tar core/gcc core/postgresql95 core/go core/git)
pkg_deps=(core/python2 core/libffi core/busybox-static core/openssl core/sysstat)
pkg_dirname="datadog-agent"
pkg_bin_dirs=(dd-agent/bin)
pkg_svc_run="agent"
pkg_svc_user="root" # needed for supervisord

do_begin() {
  export DD_HOME="${pkg_prefix}/dd-agent"
  export DD_START_AGENT=0
}

do_build() {
  return 0
}

do_install() {
  mkdir -p "$DD_HOME"

  export GOPATH="$PLAN_CONTEXT/go"
  mkdir -p "$GOPATH"

  go get github.com/DataDog/gohai
  cp "$GOPATH/bin/gohai" "$DD_HOME/bin"
  rm -rf "$GOPATH"

  env PATH="$(pkg_path_for core/tar)/bin:$PATH" sh -c "$(curl -L https://raw.githubusercontent.com/DataDog/dd-agent/master/packaging/datadog-agent/source/setup_agent.sh)"
  fix_interpreter "$DD_HOME/bin/agent" core/busybox-static bin/env
  rm -fr "$DD_HOME/logs"
  ln -s "$pkg_svc_var_path" "$DD_HOME/logs"
  mkdir -p "$pkg_prefix/config"
  cp "$PLAN_CONTEXT/config/datadog.conf" "$pkg_prefix/config"
  ln -s "$pkg_svc_config_path/datadog.conf" "$DD_HOME/agent/datadog.conf"
}

do_strip() {
  return 0
}
