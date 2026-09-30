# frozen_string_literal: true

module RepoBar
  module Runtime
    module QuickShell
      module_function

      def open(config_path, repository = nil, mode: nil)
        config = Core::Config.load_config(config_path)
        Daemon.dispatch_action(config_path, type: "open_panel", repository: repository.to_s, mode: mode.to_s)
        ensure_running(config, config_path)
        status(config_path)
      end

      def close(config_path)
        Daemon.dispatch_action(config_path, type: "close_panel")
        status(config_path)
      end

      def toggle(config_path, repository = nil)
        config = Core::Config.load_config(config_path)
        state = State.read_ui_state(config)
        state[:open] ? close(config_path) : open(config_path, repository)
      end

      def status(config_path)
        config = Core::Config.load_config(config_path)
        {
          ui: State.read_ui_state(config),
          snapshotPath: State.snapshot_path(config),
          uiPath: State.ui_state_path(config),
          searchPath: State.search_state_path(config),
          stateEventPath: State.state_event_path(config),
          quickShellRunning: running?(config)
        }
      end

      def ensure_running(config, config_path)
        return if running?(config)

        command = config.dig(:runtime, :quickShellCommand)
        shell = File.expand_path(config.dig(:runtime, :quickShellShell))
        env = {
          "REPOBAR_BIN" => repobar_executable,
          "REPOBAR_CONFIG" => File.expand_path(config_path),
          "REPOBAR_STATE_DIR" => State.state_dir(config),
          "QS_NO_RELOAD_POPUP" => "1",
          "QT_QPA_PLATFORM" => "wayland"
        }
        Core::Process.spawn_detached(command, ["--daemonize", "--no-duplicate", "--path", shell], env: env, cwd: File.dirname(shell))
      end

      def running?(config = nil)
        shell_path = File.expand_path(config&.dig(:runtime, :quickShellShell) || "../../../frontend/quickshell/shell.qml", __dir__)
        result = Core::Process.run_command("ps", ["-eo", "comm=,args="])
        result.success? && result.stdout.lines.any? do |line|
          command, args = line.strip.split(/\s+/, 2)
          command == "quickshell" && args.to_s.include?(shell_path)
        end
      rescue StandardError
        false
      end

      def repobar_executable
        candidates = [
          File.join(Dir.home, ".local", "bin", "repobar"),
          File.expand_path("../../../bin/repobar", __dir__),
          "repobar"
        ]
        candidates.find { |candidate| candidate == "repobar" || File.executable?(candidate) } || "repobar"
      end
    end
  end
end
