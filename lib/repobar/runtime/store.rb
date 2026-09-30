# frozen_string_literal: true

require "securerandom"
require "time"

module RepoBar
  module Runtime
    module Store
      module_function

      def open_panel(config_path, repository = nil, mode: nil)
        config = Core::Config.load_config(config_path)
        State.ensure_ui_state(config)
        state = State.read_ui_state(config)
        state[:open] = true
        state[:mode] = mode.to_s if %w[overview triage].include?(mode.to_s)
        state[:focusRepository] = repository.to_s if repository
        state[:requestedAt] = timestamp
        State.write_ui_state(config, state)
        state
      end

      def close_panel(config_path)
        config = Core::Config.load_config(config_path)
        state = State.read_ui_state(config)
        state[:open] = false
        state[:requestedAt] = timestamp
        State.write_ui_state(config, state)
        state
      end

      def pin_repo(config_path, full_name)
        mutate_repo_visibility(config_path, full_name) do |repo_list, normalized|
          repo_list[:hiddenRepositories].delete(normalized)
          repo_list[:pinnedRepositories] |= [normalized]
        end
      end

      def unpin_repo(config_path, full_name)
        mutate_repo_visibility(config_path, full_name) do |repo_list, normalized|
          repo_list[:pinnedRepositories].delete(normalized)
        end
      end

      def move_pinned_repo(config_path, full_name, position)
        normalized = normalize_full_name(full_name)
        config = Core::Config.load_config(config_path)
        pinned = Array(config.dig(:repoList, :pinnedRepositories))
        current_index = pinned.index(normalized)
        raise ArgumentError, "Pinned repository not found: #{normalized}" unless current_index

        pinned.delete_at(current_index)
        target_index = [[position.to_i, 0].max, pinned.length].min
        pinned.insert(target_index, normalized)
        config[:repoList][:pinnedRepositories] = pinned
        saved = Core::Config.save_config(config, config_path)
        project_repo_visibility(saved, normalized)
        saved[:repoList]
      end

      def hide_repo(config_path, full_name)
        mutate_repo_visibility(config_path, full_name) do |repo_list, normalized|
          repo_list[:pinnedRepositories].delete(normalized)
          repo_list[:hiddenRepositories] |= [normalized]
        end
      end

      def show_repo(config_path, full_name)
        mutate_repo_visibility(config_path, full_name) do |repo_list, normalized|
          repo_list[:hiddenRepositories].delete(normalized)
        end
      end

      def start_search(config_path, query, limit:)
        config = Core::Config.load_config(config_path)
        clean_query = query.to_s.strip
        raise ArgumentError, "Search query required." if clean_query.empty?

        state = {
          status: "loading",
          query: clean_query,
          requestId: SecureRandom.hex(8),
          selectedFullName: "",
          results: [],
          error: "",
          updatedAt: timestamp
        }
        State.write_search_state(config, state)
        State.read_search_state(config)
      end

      def select_search_result(config_path, full_name)
        config = Core::Config.load_config(config_path)
        state = State.read_search_state(config)
        normalized = normalize_full_name(full_name)
        result = Array(state[:results]).find { |repo| repo[:fullName].to_s.downcase == normalized }
        raise ArgumentError, "Search result not found: #{full_name}" unless result

        state[:selectedFullName] = normalized
        state[:updatedAt] = timestamp
        State.write_search_state(config, state)
        State.read_search_state(config)
      end

      def finish_search(config_path, request_id, query, results: [], error: nil)
        config = Core::Config.load_config(config_path)
        current = State.read_search_state(config)
        return current if current[:requestId].to_s != request_id.to_s

        state = current.merge(
          status: error.to_s.empty? ? "ready" : "error",
          query: query.to_s,
          results: Array(results),
          error: error.to_s,
          selectedFullName: "",
          updatedAt: timestamp
        )
        State.write_search_state(config, state)
        State.read_search_state(config)
      end

      def start_thread(config_path, item_id, repository, number, kind, title: nil, url: nil)
        config = Core::Config.load_config(config_path)
        clean_id = item_id.to_s.strip.downcase
        raise ArgumentError, "Thread item id required as owner/name#number." unless clean_id.match?(%r{\A[^/\s]+/[^/\s]+#\d+\z})
        raise ArgumentError, "Thread kind must be issue or pr." unless %w[issue pr].include?(kind.to_s)
        expected_id = "#{repository.to_s.downcase}##{number}"
        raise ArgumentError, "Thread identity does not match repository and number." unless clean_id == expected_id && number.to_i.positive?
        clean_kind = kind.to_s

        state = {
          status: "loading",
          itemId: clean_id,
          repoFullName: repository.to_s,
          number: number.to_s,
          kind: clean_kind,
          title: title.to_s,
          url: url.to_s,
          requestId: SecureRandom.hex(8),
          entries: [],
          truncated: false,
          error: "",
          updatedAt: timestamp
        }
        State.with_thread_lock(config) do
          current = State.read_thread_state(config)
          if current[:itemId].to_s == clean_id
            state[:entries] = current[:entries]
            state[:truncated] = current[:truncated]
          end
          State.write_thread_state(config, state)
          State.read_thread_state(config)
        end
      end

      def finish_thread(config_path, request_id, entries:, truncated: false, error: nil)
        config = Core::Config.load_config(config_path)
        State.with_thread_lock(config) do
          current = State.read_thread_state(config)
          return current if current[:requestId].to_s != request_id.to_s

          state = current.merge(
            status: error.to_s.empty? ? "ready" : "error",
            entries: error.to_s.empty? ? Array(entries) : current[:entries],
            truncated: error.to_s.empty? ? !!truncated : current[:truncated],
            error: error.to_s,
            updatedAt: timestamp
          )
          State.write_thread_state(config, state)
          State.read_thread_state(config)
        end
      end

      # Read the cached thread for an item without touching the network. The panel
      # uses this to show a thread it has already fetched while a refresh runs.
      def cached_thread(config, item_id)
        state = State.read_thread_state(config)
        return nil if state[:itemId].to_s != item_id.to_s.downcase

        state
      end

      def commit_refresh(config, repositories, local_repositories, account)
        write_projection(config, State.build_snapshot(config, repositories, local_repositories, account))
      end

      def refresh_effect(config_path)
        config = Core::Config.load_config(config_path)
        started_identity = refresh_identity(config)
        account = Core::GitHub.auth_status(config)
        if account[:authenticated] && config.dig(:settings, :showContributionHeader)
          account[:heatmap] = Core::GitHub.account_heatmap(config, Core::GitHub.access_token(config), account[:login])
        end
        repositories = Core::GitHub.fetch_repositories(config)
        local_repositories = Core::LocalGit.scan(config)
        repositories = Core::LocalGit.match_repositories(repositories, local_repositories)
        current = Core::Config.load_config(config_path)
        return commit_refresh(current, repositories, local_repositories, account) if refresh_identity(current) == started_identity

        # The user changed config while this refresh was in flight (pinned order,
        # hidden/visible repositories, local roots, or state dir). Re-project the
        # fresh rows through the newer config so a late refresh cannot clobber
        # visibility state that was written after the refresh started.
        snapshot = stale_refresh_snapshot(current, repositories, local_repositories, account)
        write_projection(stale_refresh_target_config(config, current), snapshot)
      end

      def search_effect(config_path, query, limit, request_id)
        config = Core::Config.load_config(config_path)
        rows = Core::GitHub.search_repositories(config, Core::GitHub.access_token(config), query, limit)
        finish_search(config_path, request_id, query, results: rows)
      rescue StandardError => e
        finish_search(config_path, request_id, query, error: e.message)
      end

      # Reuse fresh REST responses locally; expired entries are revalidated with
      # If-None-Match when GitHub supplied an ETag.
      def thread_effect(config_path, item_id, repository, number, kind, request_id, limit)
        config = Core::Config.load_config(config_path)
        token = Core::GitHub.access_token(config)
        owner, name = repository.to_s.split("/", 2)
        fetch_limit = limit.to_i.positive? ? limit.to_i + 1 : nil
        entries = Core::GitHub.item_thread(config, token, owner, name, number, kind, fetch_limit)
        truncated = limit.to_i.positive? && entries.length > limit.to_i
        entries = entries.last(limit.to_i) if truncated
        view = Presenter.thread_view(entries: entries)
        finish_thread(config_path, request_id, entries: view[:entries], truncated: truncated)
      rescue StandardError => e
        finish_thread(config_path, request_id, entries: [], error: e.message)
      end

      def signal_waybar(config)
        signal = config.dig(:runtime, :waybarSignal).to_i
        return if signal <= 0

        Core::Process.run_command("pkill", ["-RTMIN+#{signal}", "waybar"])
      rescue StandardError
        nil
      end

      def mutate_repo_visibility(config_path, full_name)
        normalized = normalize_full_name(full_name)
        config = Core::Config.load_config(config_path)
        repo_list = config[:repoList]
        yield(repo_list, normalized)
        saved = Core::Config.save_config(config, config_path)
        project_repo_visibility(saved, normalized)
        saved[:repoList]
      end

      def project_repo_visibility(config, changed_full_name)
        previous = State.read_snapshot(config)
        repositories = Array(previous && previous[:repositories]).map { |repo| deep_dup(repo) }
        repositories = ensure_projected_repo(config, repositories, changed_full_name)
        hidden = Array(config.dig(:repoList, :hiddenRepositories))
        repositories.reject! { |repo| hidden.include?(repo[:fullName].to_s.downcase) }
        repositories = order_repositories_for_config(config, repositories)
        commit_projection(config, repositories: repositories, local_repositories: Array(previous && previous[:localRepositories]), account: deep_dup(previous && previous[:account]) || {})
      end

      def ensure_projected_repo(config, repositories, full_name)
        pinned = Array(config.dig(:repoList, :pinnedRepositories))
        return repositories unless pinned.include?(full_name)
        return repositories if repositories.any? { |repo| repo[:fullName].to_s.downcase == full_name }

        search_repo = Array(State.read_search_state(config)[:results]).find { |repo| repo[:fullName].to_s.downcase == full_name }
        repositories.unshift((search_repo ? deep_dup(search_repo) : lightweight_repo(config, full_name)).merge(pending: true))
        repositories
      end

      def order_repositories_for_config(config, repositories)
        pinned_positions = Array(config.dig(:repoList, :pinnedRepositories)).each_with_index.to_h
        repositories.sort_by.with_index do |repo, index|
          full_name = repo[:fullName].to_s.downcase
          pinned_positions.key?(full_name) ? [0, pinned_positions[full_name]] : [1, index]
        end
      end

      def stale_refresh_snapshot(current_config, repositories, local_repositories, account)
        current_repositories = repositories.map { |repo| deep_dup(repo) }
        hidden = Array(current_config.dig(:repoList, :hiddenRepositories))
        current_repositories.reject! { |repo| hidden.include?(repo[:fullName].to_s.downcase) }
        active_repositories = Array(State.read_snapshot(current_config)&.dig(:repositories))
        Array(current_config.dig(:repoList, :pinnedRepositories)).each do |full_name|
          next if current_repositories.any? { |repo| repo[:fullName].to_s.downcase == full_name }

          active_repo = active_repositories.find { |repo| repo[:fullName].to_s.downcase == full_name }
          current_repositories << (active_repo ? deep_dup(active_repo) : lightweight_repo(current_config, full_name))
        end
        current_repositories = order_repositories_for_config(current_config, current_repositories)
        State.build_snapshot(current_config, current_repositories, local_repositories, account)
      end

      # A refresh that started against a different state directory belongs to that
      # directory; everything else writes back to the current config location.
      def stale_refresh_target_config(started_config, current_config)
        return started_config if current_config.dig(:runtime, :stateDir) != started_config.dig(:runtime, :stateDir)

        current_config
      end

      def commit_projection(config, repositories:, local_repositories:, account:)
        write_projection(config, State.build_snapshot(config, repositories, local_repositories, account))
      end

      def write_projection(config, snapshot)
        State.write_snapshot(config, snapshot)
        signal_waybar(config)
        snapshot
      end

      def lightweight_repo(config, full_name)
        owner, name = full_name.split("/", 2)
        host = config.dig(:github, :host).to_s.sub(%r{/*\z}, "")
        {
          id: full_name,
          fullName: full_name,
          owner: owner,
          name: name,
          description: "Pending refresh",
          url: "#{host}/#{full_name}",
          private: false,
          fork: false,
          archived: false,
          updatedAt: Time.now.utc.iso8601,
          stats: {
            stars: 0,
            forks: 0,
            pushedAt: Time.now.utc.iso8601,
            openIssues: 0,
            openPulls: 0
          },
          ciStatus: "unknown",
          pending: true
        }
      end

      def normalize_full_name(full_name)
        text = full_name.to_s.strip.downcase
        raise ArgumentError, "Repository required as owner/name." unless text.match?(%r{\A[^/\s]+/[^/\s]+\z})

        text
      end

      def deep_dup(value)
        Marshal.load(Marshal.dump(value))
      end

      def refresh_identity(config)
        {
          github: config[:github],
          repoList: config[:repoList],
          settings: { showContributionHeader: config.dig(:settings, :showContributionHeader) },
          localProjects: config[:localProjects],
          stateDir: config.dig(:runtime, :stateDir)
        }
      end

      def timestamp
        Time.now.utc.iso8601(6)
      end

      def repobar_executable
        candidate = File.expand_path("../../../bin/repobar", __dir__)
        return candidate if File.executable?(candidate)

        "repobar"
      end
    end
  end
end
