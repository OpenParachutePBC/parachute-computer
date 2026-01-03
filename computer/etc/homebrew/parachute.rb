class Parachute < Formula
  desc "AI orchestration server for your knowledge vault"
  homepage "https://github.com/OpenParachutePBC/parachute"
  url "https://github.com/OpenParachutePBC/parachute-base/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "1cff8bdcd400e48c7a4b56ea038e31d7eb0e6a099e15b280380a5493b3daf86e"
  license "MIT"
  head "https://github.com/OpenParachutePBC/parachute-base.git", branch: "main"

  depends_on "python@3.13"

  # Note: This formula installs the wrapper scripts and CLI.
  # Users need to run `parachute setup` on first use to install Python dependencies.

  def install
    # Install the Python packages to libexec
    libexec.install Dir["parachute", "supervisor", "requirements.txt"]

    # Create wrapper scripts
    (bin/"parachute-server").write <<~EOS
      #!/bin/bash
      SCRIPT_DIR="#{libexec}"
      if [ ! -d "$SCRIPT_DIR/venv" ]; then
        echo "Setting up Python environment..."
        python3.13 -m venv "$SCRIPT_DIR/venv"
        "$SCRIPT_DIR/venv/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt"
      fi
      export VIRTUAL_ENV="$SCRIPT_DIR/venv"
      export PATH="$SCRIPT_DIR/venv/bin:$PATH"
      export PYTHONPATH="$SCRIPT_DIR:$PYTHONPATH"
      exec "$SCRIPT_DIR/venv/bin/python" -m parachute.server "$@"
    EOS

    (bin/"parachute-supervisor").write <<~EOS
      #!/bin/bash
      SCRIPT_DIR="#{libexec}"
      if [ ! -d "$SCRIPT_DIR/venv" ]; then
        echo "Setting up Python environment..."
        python3.13 -m venv "$SCRIPT_DIR/venv"
        "$SCRIPT_DIR/venv/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt"
      fi
      export VIRTUAL_ENV="$SCRIPT_DIR/venv"
      export PATH="$SCRIPT_DIR/venv/bin:$PATH"
      export PYTHONPATH="$SCRIPT_DIR:$PYTHONPATH"
      exec "$SCRIPT_DIR/venv/bin/python" -m supervisor.main "$@"
    EOS

    # Install the management CLI script
    bin.install "parachute.sh" => "parachute"
  end

  def post_install
    # Create log and data directories
    (var/"log").mkpath
    (var/"parachute").mkpath

    # Pre-install dependencies
    ohai "Setting up Python environment..."
    system bin/"parachute-server", "--help" rescue nil
  end

  service do
    run [opt_bin/"parachute-server"]
    environment_variables VAULT_PATH: "#{Dir.home}/Parachute",
                          PORT: "3333",
                          HOST: "0.0.0.0"
    keep_alive true
    log_path var/"log/parachute.log"
    error_log_path var/"log/parachute.log"
    working_dir var/"parachute"
  end

  def caveats
    <<~EOS
      Parachute Base Server has been installed!

      First run will install Python dependencies (one-time setup).

      To start now and restart at login:
        brew services start parachute

      Or run manually:
        parachute-server

      With supervisor (web UI at http://localhost:3330):
        parachute-supervisor

      Using the CLI:
        parachute start      # Start server
        parachute status     # Check status
        parachute stop       # Stop server

      Configuration:
        Vault: ~/Parachute (override with VAULT_PATH)
        Port:  3333 (override with PORT)
        Logs:  #{var}/log/parachute.log
    EOS
  end

  test do
    assert_match "Usage", shell_output("#{bin}/parachute help")
  end
end
