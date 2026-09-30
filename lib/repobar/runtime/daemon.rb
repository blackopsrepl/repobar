# frozen_string_literal: true

require "json"
require "fileutils"
require "socket"
require "securerandom"
require "time"

module RepoBar
  module Runtime
    module Daemon
      module_function

      def run(config_path, once: false)
        config = Core::Config.load_config(config_path)
        return refresh(config_path, config: config) if once

        lock = State.acquire_daemon_lock(config)
        raise "repobar daemon already running for #{State.state_dir(config)}." unless lock

        State.ensure_ui_state(config)
        run_action_server(config_path, config)
      ensure
        lock&.close
      end

      def refresh(config_path, config: nil)
        config ||= Core::Config.load_config(config_path)
        snapshot = nil
        State.with_refresh_lock(config) do
          snapshot = Store.refresh_effect(config_path)
        end
        snapshot
      end

      def dispatch_action(config_path, action)
        config = Core::Config.load_config(config_path)
        ensure_running(config_path, config)
        socket_path = State.daemon_socket_path(config)
        UNIXSocket.open(socket_path) do |socket|
          socket.write("#{JSON.generate(action)}\n")
          socket.flush
          response = socket.gets
          raise "repobar daemon closed the action socket." unless response

          payload = JSON.parse(response, symbolize_names: true)
          raise payload[:error].to_s unless payload[:ok]

          payload[:result]
        end
      end

      def ensure_running(config_path, config = nil)
        config ||= Core::Config.load_config(config_path)
        return if socket_ready?(config)

        stop_socketless_daemon(config)
        Core::Process.spawn_detached(Store.repobar_executable, ["daemon", "--config", File.expand_path(config_path)])
        deadline = Time.now + 3
        sleep 0.05 until socket_ready?(config) || Time.now >= deadline
        raise "repobar daemon did not start for #{State.state_dir(config)}." unless socket_ready?(config)
      end

      def stop_socketless_daemon(config)
        pid = State.daemon_pid(config)
        return unless pid
        return unless process_alive?(pid)

        command = Core::Process.run_command("ps", ["-p", pid.to_s, "-o", "args="])
        return unless command.success? && command.stdout.include?("repobar") && command.stdout.include?("daemon")

        ::Process.kill("TERM", pid)
        deadline = Time.now + 1
        sleep 0.05 while process_alive?(pid) && Time.now < deadline
      rescue StandardError
        nil
      end

      def process_alive?(pid)
        ::Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def run_action_server(config_path, initial_config)
        socket_path = State.daemon_socket_path(initial_config)
        FileUtils.rm_f(socket_path)
        server = UNIXServer.new(socket_path)
        File.chmod(0o600, socket_path)
        next_refresh_at = Time.now
        refresh_state = { thread: nil, pending: false, mutex: Mutex.new }
        search_threads = []
        mutex = Mutex.new

        loop do
          config = Core::Config.load_config(config_path)
          if Time.now >= next_refresh_at
            request_refresh(config_path, refresh_state, queue_pending: false)
            next_refresh_at = Time.now + config.dig(:runtime, :refreshSeconds).to_i
          end

          ready = IO.select([server], nil, nil, 0.25)
          next unless ready

          client = server.accept
          request = client.gets
          result = handle_action(config_path, JSON.parse(request.to_s, symbolize_names: true), mutex, search_threads, refresh_state)
          client.write("#{JSON.generate(ok: true, result: result)}\n")
        rescue StandardError => e
          client&.write("#{JSON.generate(ok: false, error: e.message)}\n")
          warn "repobar daemon action error: #{e.message}"
        ensure
          client&.close
          search_threads.reject! { |thread| !thread.alive? }
        end
      ensure
        server&.close
        FileUtils.rm_f(socket_path) if socket_path
      end

      def handle_action(config_path, action, mutex, search_threads, refresh_state)
        type = action[:type].to_s
        result = nil
        refresh_needed = false
        search_job = nil

        mutex.synchronize do
          case type
          when "open_panel"
            result = Store.open_panel(config_path, action[:repository], mode: action[:mode])
          when "close_panel"
            result = Store.close_panel(config_path)
          when "set_provider"
            result = Store.set_provider(config_path, action[:provider].to_s, host: action[:host])
            refresh_needed = true
          when "pin"
            result = Store.pin_repo(config_path, action[:fullName])
            refresh_needed = true
          when "unpin"
            result = Store.unpin_repo(config_path, action[:fullName])
            refresh_needed = true
          when "pin_move"
            result = Store.move_pinned_repo(config_path, action[:fullName], action[:position])
          when "hide"
            result = Store.hide_repo(config_path, action[:fullName])
            refresh_needed = true
          when "show"
            result = Store.show_repo(config_path, action[:fullName])
            refresh_needed = true
          when "refresh"
            result = { status: "refresh_requested" }
            refresh_needed = true
          when "search_start"
            result = Store.start_search(config_path, action[:query].to_s, limit: action[:limit].to_i.positive? ? action[:limit].to_i : 10)
            search_job = [result[:query], action[:limit].to_i.positive? ? action[:limit].to_i : 10, result[:requestId]]
          when "search_select"
            result = Store.select_search_result(config_path, action[:fullName])
          when "ping"
            result = { status: "ok" }
          else
            raise ArgumentError, "Unknown daemon action: #{type}"
          end
        end

        request_refresh(config_path, refresh_state) if refresh_needed
        search_threads << start_search_thread(config_path, *search_job) if search_job
        result
      end

      def request_refresh(config_path, refresh_state, queue_pending: true)
        refresh_state[:mutex].synchronize do
          if refresh_state[:thread]&.alive?
            refresh_state[:pending] = true if queue_pending
            return refresh_state[:thread]
          end

          refresh_state[:pending] = false
          refresh_state[:thread] = Thread.new { refresh_loop(config_path, refresh_state) }
        end
      end

      def refresh_loop(config_path, refresh_state)
        loop do
          refresh(config_path)
          repeat = refresh_state[:mutex].synchronize do
            if refresh_state[:pending]
              refresh_state[:pending] = false
              true
            else
              refresh_state[:thread] = nil
              false
            end
          end
          break unless repeat
        end
      rescue StandardError => e
        refresh_state[:mutex].synchronize do
          refresh_state[:thread] = nil
          refresh_state[:pending] = false
        end
        warn "repobar daemon refresh error: #{e.message}"
      end

      def start_search_thread(config_path, query, limit, request_id)
        Thread.new do
          Store.search_effect(config_path, query, limit, request_id)
        rescue StandardError => e
          warn "repobar daemon search error: #{e.message}"
        end
      end

      def socket_ready?(config)
        socket_path = State.daemon_socket_path(config)
        return false unless File.socket?(socket_path)

        UNIXSocket.open(socket_path) do |socket|
          socket.write("#{JSON.generate(type: "ping")}\n")
          socket.flush
          response = socket.gets
          response && JSON.parse(response, symbolize_names: true)[:ok]
        end
      rescue StandardError
        false
      end

      def signal_waybar(config)
        Store.signal_waybar(config)
      end
    end
  end
end
