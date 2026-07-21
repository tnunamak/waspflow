class WaspflowFederation < Formula
  desc "Local Federation daemon, browser UI, and native tray helper for Waspflow"
  homepage "https://github.com/tnunamak/waspflow"
  url "https://github.com/tnunamak/waspflow/archive/refs/tags/v0.0.0.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_TARBALL_SHA256"
  license "MIT"

  depends_on "go" => :build
  depends_on "node@20"
  depends_on "tnunamak/clawmeter/clawmeter"

  def install
    libexec.install "bin", "lib", "public"
    ln_s Formula["tnunamak/clawmeter/clawmeter"].opt_bin/"clawmeter", libexec/"clawmeter"
    system "go", "build", "-trimpath", "-o", libexec/"waspflow-federation-tray", "./tray/cmd/waspflow-federation-tray"

    (bin/"waspflow-federation").write <<~EOS
      #!/bin/sh
      export PATH="#{libexec}:$PATH"
      if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        "#{Formula["node@20"].opt_bin}/node" "#{libexec}/bin/waspflow-federation" "$@"
        status=$?
        [ "$status" -eq 1 ] && exit 0
        exit "$status"
      fi
      exec "#{Formula["node@20"].opt_bin}/node" "#{libexec}/bin/waspflow-federation" "$@"
    EOS

    # This preserves the documented contributor command and the tray's daemon
    # start path without installing the unrelated orchestration CLI.
    (bin/"waspflow").write <<~EOS
      #!/bin/sh
      if [ "$1" = federation ]; then
        shift
        exec "#{bin}/waspflow-federation" "$@"
      fi
      echo "This formula provides only: waspflow federation ..." >&2
      exit 64
    EOS
  end

  test do
    assert_match "usage: waspflow federation", shell_output("#{bin}/waspflow federation --help")
    assert_predicate libexec/"waspflow-federation-tray", :executable?
  end

  service do
    run [opt_bin/"waspflow-federation", "daemon"]
    keep_alive false
    log_path var/"log/waspflow-federation.log"
    error_log_path var/"log/waspflow-federation.log"
  end

  def caveats
    <<~EOS
      Start the local Federation daemon:
        brew services start waspflow-federation

      Check the sandbox backend before contributing:
        waspflow federation doctor
    EOS
  end
end
