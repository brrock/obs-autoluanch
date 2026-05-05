class ObsAutoluanch < Formula
  desc "Launch OBS scenes when configured macOS apps open"
  homepage "https://github.com/brrock/obs-autoluanch"
  license "MIT"
  head "https://github.com/brrock/obs-autoluanch.git", branch: "main"

  depends_on "zig" => :build

  def install
    system "zig", "build", "-Doptimize=ReleaseSafe", "--prefix", prefix
  end

  def post_install
    (var/"log").mkpath
  end

  service do
    run [opt_bin/"obs-autoluanch", "daemon"]
    keep_alive true
    log_path var/"log/obs-autoluanch.log"
    error_log_path var/"log/obs-autoluanch.log"
  end

  def caveats
    <<~EOS
      Create or edit the default service config with:
        obs-autoluanch config

      The default config path is:
        ~/.config/obsautolaunch/config.json

      Start the daemon:
        brew services start obs-autoluanch

      Check whether it is running:
        obs-autoluanch status
    EOS
  end

  test do
    output = shell_output("#{bin}/obs-autoluanch status 2>&1", 1)
    assert_match "not running", output
  end
end
