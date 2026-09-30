# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module RepoBar
  module Runtime
    module State
      SNAPSHOT_VERSION = 1
      SNAPSHOT_FILE = "snapshot.json"
      UI_STATE_FILE = "ui.json"
      SEARCH_STATE_FILE = "search.json"
      STATE_EVENT_FILE = "state-event.json"
      DAEMON_LOCK_FILE = "daemon.lock"
      DAEMON_SOCKET_FILE = "daemon.sock"
      REFRESH_LOCK_FILE = "refresh.lock"

      module_function

      def state_dir(config)
        File.expand_path(config.dig(:runtime, :stateDir))
      end

      def snapshot_path(config)
        File.join(state_dir(config), SNAPSHOT_FILE)
      end

      def provider_snapshot_path(config, provider = nil)
        selected = provider || config.dig(:github, :provider)
        File.join(state_dir(config), "providers", "#{selected == "forgejo" ? "forgejo" : "github"}.json")
      end

      def ui_state_path(config)
        File.join(state_dir(config), UI_STATE_FILE)
      end

      def search_state_path(config)
        File.join(state_dir(config), SEARCH_STATE_FILE)
      end

      def state_event_path(config)
        File.join(state_dir(config), STATE_EVENT_FILE)
      end

      def daemon_socket_path(config)
        File.join(state_dir(config), DAEMON_SOCKET_FILE)
      end

      def read_snapshot(config)
        path = snapshot_path(config)
        return nil unless File.file?(path)

        JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      def write_snapshot(config, snapshot)
        ensure_state_dir(config)
        atomic_write_json(snapshot_path(config), snapshot)
        write_provider_snapshot(config, snapshot)
        notify_state_change(config)
      end

      def read_provider_snapshot(config, provider = nil)
        path = provider_snapshot_path(config, provider)
        return nil unless File.file?(path)

        JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      def write_provider_snapshot(config, snapshot, provider = nil)
        return unless snapshot

        ensure_state_dir(config)
        atomic_write_json(provider_snapshot_path(config, provider || snapshot.dig(:config, :provider)), snapshot)
      end

      def build_snapshot(config, repositories, local_repositories, account, now = Time.now.utc)
        snapshot = {
          snapshotVersion: SNAPSHOT_VERSION,
          generatedAt: now.iso8601,
          config: {
            refreshSeconds: config.dig(:runtime, :refreshSeconds),
            provider: config.dig(:github, :provider)
          },
          account: account,
          repositories: repositories,
          localRepositories: local_repositories
        }
        snapshot[:view] = Presenter.build_snapshot_view(config, snapshot, now)
        snapshot
      end

      def stale?(snapshot, config, now = Time.now)
        generated = Core::Format.parse_time(snapshot && snapshot[:generatedAt])
        return true unless generated

        generated < (now - stale_after_seconds(config))
      end

      def stale_after_seconds(config)
        [config.dig(:refreshSeconds).to_i * 2, 120].max
      end

      def read_ui_state(config)
        path = ui_state_path(config)
        return default_ui_state unless File.file?(path)

        normalize_ui_state(JSON.parse(File.read(path), symbolize_names: true))
      rescue JSON::ParserError
        default_ui_state
      end

      def write_ui_state(config, ui_state)
        ensure_state_dir(config)
        atomic_write_json(ui_state_path(config), normalize_ui_state(ui_state))
        notify_state_change(config)
      end

      def read_search_state(config)
        path = search_state_path(config)
        return default_search_state unless File.file?(path)

        normalize_search_state(JSON.parse(File.read(path), symbolize_names: true))
      rescue JSON::ParserError
        default_search_state
      end

      def write_search_state(config, search_state)
        ensure_state_dir(config)
        atomic_write_json(search_state_path(config), normalize_search_state(search_state))
        notify_state_change(config)
      end

      def default_ui_state
        {
          open: false,
          mode: "overview",
          focusRepository: "",
          requestedAt: ""
        }
      end

      def default_search_state
        {
          status: "idle",
          query: "",
          requestId: "",
          selectedFullName: "",
          results: [],
          error: "",
          updatedAt: ""
        }
      end

      def normalize_ui_state(ui_state)
        state = default_ui_state.merge((ui_state || {}).transform_keys(&:to_sym))
        mode = %w[overview triage].include?(state[:mode].to_s) ? state[:mode].to_s : "overview"
        {
          open: !!state[:open],
          mode: mode,
          focusRepository: state[:focusRepository].to_s,
          requestedAt: state[:requestedAt].to_s
        }
      end

      def normalize_search_state(search_state)
        state = default_search_state.merge((search_state || {}).transform_keys(&:to_sym))
        status = %w[idle loading ready error].include?(state[:status].to_s) ? state[:status].to_s : "idle"
        {
          status: status,
          query: state[:query].to_s,
          requestId: state[:requestId].to_s,
          selectedFullName: state[:selectedFullName].to_s.downcase,
          results: Array(state[:results]),
          error: state[:error].to_s,
          updatedAt: state[:updatedAt].to_s
        }
      end

      def ensure_ui_state(config)
        ensure_state_dir(config)
        ensure_state_event(config)
        write_ui_state(config, default_ui_state) unless File.file?(ui_state_path(config))
        write_search_state(config, default_search_state) unless File.file?(search_state_path(config))
      end

      def with_refresh_lock(config)
        ensure_state_dir(config)
        File.open(lock_path(config, REFRESH_LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          yield
        end
      end

      def acquire_daemon_lock(config)
        ensure_state_dir(config)
        file = File.open(lock_path(config, DAEMON_LOCK_FILE), File::RDWR | File::CREAT, 0o600)
        return nil unless file.flock(File::LOCK_EX | File::LOCK_NB)

        file.rewind
        file.write("#{::Process.pid}\n")
        file.flush
        file
      rescue Errno::EWOULDBLOCK, Errno::EAGAIN
        nil
      end

      def daemon_pid(config)
        path = lock_path(config, DAEMON_LOCK_FILE)
        return nil unless File.file?(path)

        pid = File.read(path).to_i
        pid.positive? ? pid : nil
      rescue StandardError
        nil
      end

      def ensure_state_dir(config)
        FileUtils.mkdir_p(state_dir(config))
      end

      def ensure_state_event(config)
        notify_state_change(config) unless File.file?(state_event_path(config))
      end

      def notify_state_change(config)
        ensure_state_dir(config)
        write_watched_json(state_event_path(config), updatedAt: Time.now.utc.iso8601(6))
      end

      def atomic_write_json(path, payload)
        FileUtils.mkdir_p(File.dirname(path))
        temp_path = "#{path}.tmp.#{$$}"
        File.write(temp_path, "#{JSON.pretty_generate(payload)}\n")
        File.chmod(0o600, temp_path)
        File.rename(temp_path, path)
        File.chmod(0o600, path)
        path
      ensure
        FileUtils.rm_f(temp_path) if temp_path && File.exist?(temp_path)
      end

      def write_watched_json(path, payload)
        contents = "#{JSON.generate(payload)}\n"
        File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
          file.rewind
          file.write(contents)
          file.truncate(file.pos)
          file.flush
          file.fsync
        end
        File.chmod(0o600, path)
        path
      end

      def lock_path(config, name)
        File.join(state_dir(config), name)
      end
    end
  end
end
