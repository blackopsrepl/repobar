# frozen_string_literal: true

require "fileutils"
require "json"

module RepoBar
  module Core
    module Config
      CONFIG_VERSION = 1
      DEFAULT_QUICKSHELL_COMMAND = "quickshell"
      GITHUB_HOST = "https://github.com"
      GITHUB_API_HOST = "https://api.github.com"
      AUTH_SOURCES = %w[gh env].freeze

      module_function

      def default_config
        {
          version: CONFIG_VERSION,
          github: {
            host: GITHUB_HOST,
            apiHost: GITHUB_API_HOST,
            authSource: "gh"
          },
          repoList: {
            displayLimit: 5,
            menuSort: "activity",
            showForks: false,
            showArchived: false,
            visibleRepositories: [],
            pinnedRepositories: [],
            hiddenRepositories: []
          },
          settings: {
            showContributionHeader: true,
            showRateLimitMeter: true,
            cardDensity: "comfortable",
            accentTone: "github-green",
            activityScope: "all",
            heatmapDisplay: "inline",
            heatmapSpan: "6m",
            launchAtLogin: true,
            localGhosttyMode: "new-window"
          },
          localProjects: {
            roots: default_local_roots,
            maxDepth: 4,
            showDirtyFiles: true,
            autoSync: false,
            fetchIntervalSeconds: 300,
            worktreeFolder: ".work",
            preferredTerminal: "kitty"
          },
          archives: {
            sources: [],
            preferArchiveWhenRateLimited: true,
            staleAfterSeconds: 900
          },
          runtime: {
            refreshSeconds: 300,
            stateDir: File.join(Dir.home, ".local", "state", "repobar"),
            waybarSignal: 10,
            quickShellCommand: DEFAULT_QUICKSHELL_COMMAND,
            quickShellShell: default_quickshell_shell
          }
        }
      end

      def default_local_roots
        [
          File.join(Dir.home, "hack"),
          "/srv/lab/hack",
          "/srv/lab/dev",
          "/srv/lab/sites",
          "/srv/lab/tools"
        ].select { |path| Dir.exist?(path) }
      end

      def default_quickshell_shell
        File.expand_path("../../../frontend/quickshell/shell.qml", __dir__)
      end

      def default_config_path
        File.join(Dir.home, ".repobar", "config.json")
      end

      def load_config(config_path = default_config_path)
        raw = File.read(config_path)
        normalize_config(JSON.parse(raw, symbolize_names: true))
      rescue Errno::ENOENT
        default_config
      end

      def save_config(config, config_path = default_config_path)
        normalized = normalize_config(config)
        FileUtils.mkdir_p(File.dirname(config_path))
        File.write(config_path, "#{JSON.pretty_generate(normalized)}\n")
        File.chmod(0o600, config_path)
        normalized
      end

      def init_config(config_path = default_config_path)
        save_config(default_config, config_path)
      end

      def normalize_config(input)
        input ||= {}
        defaults = default_config
        {
          version: CONFIG_VERSION,
          github: normalize_github(input[:github] || defaults[:github]),
          repoList: normalize_repo_list(input[:repoList] || {}),
          settings: normalize_settings(input[:settings] || {}),
          localProjects: normalize_local_projects(input[:localProjects] || {}),
          archives: normalize_archives(input[:archives] || input[:githubArchives] || {}),
          runtime: normalize_runtime(input[:runtime] || {})
        }
      end

      def validate_config(config)
        issues = []
        issues << issue("error", "version", "Expected #{CONFIG_VERSION}.") unless config[:version] == CONFIG_VERSION
        auth_source = config.dig(:github, :authSource).to_s
        unless AUTH_SOURCES.include?(auth_source)
          issues << issue("error", "github.authSource", "Must be one of #{AUTH_SOURCES.join(', ')}.")
        end
        issues << issue("warning", "runtime.refreshSeconds", "Refresh below 60 seconds can burn GitHub budget.") if config.dig(:runtime, :refreshSeconds).to_i < 60
        shell = config.dig(:runtime, :quickShellShell).to_s
        issues << issue("warning", "runtime.quickShellShell", "QuickShell shell not found at #{shell}.") unless File.file?(shell)
        Array(config.dig(:localProjects, :roots)).each do |root|
          issues << issue("warning", "localProjects.roots", "Local root not found: #{root}.") unless Dir.exist?(File.expand_path(root))
        end
        issues
      end

      # RepoBar only speaks the GitHub.com REST/GraphQL API, which is https-only.
      # A config pointing at anything else (an old local host, say) falls back to
      # the GitHub defaults instead of loading a dead endpoint.
      def normalize_github(input)
        input = (input || {}).transform_keys(&:to_sym)
        {
          host: https_host(input[:host]) || GITHUB_HOST,
          apiHost: https_host(input[:apiHost]) || GITHUB_API_HOST,
          authSource: clean(input[:authSource]) || "gh"
        }
      end

      def normalize_repo_list(input)
        input = (input || {}).transform_keys(&:to_sym)
        {
          displayLimit: positive_int(input[:displayLimit], 5),
          menuSort: %w[activity issues prs stars repo].include?(input[:menuSort].to_s) ? input[:menuSort].to_s : "activity",
          showForks: boolean(input[:showForks], false),
          showArchived: boolean(input[:showArchived], false),
          visibleRepositories: normalize_full_names(input[:visibleRepositories]),
          pinnedRepositories: normalize_full_names(input[:pinnedRepositories]),
          hiddenRepositories: normalize_full_names(input[:hiddenRepositories])
        }
      end

      def normalize_settings(input)
        input = (input || {}).transform_keys(&:to_sym)
        {
          showContributionHeader: boolean(input[:showContributionHeader], true),
          showRateLimitMeter: boolean(input[:showRateLimitMeter], true),
          cardDensity: %w[comfortable compact].include?(input[:cardDensity].to_s) ? input[:cardDensity].to_s : "comfortable",
          accentTone: %w[system github-green].include?(input[:accentTone].to_s) ? input[:accentTone].to_s : "github-green",
          activityScope: %w[all my].include?(input[:activityScope].to_s) ? input[:activityScope].to_s : "all",
          heatmapDisplay: %w[inline submenu].include?(input[:heatmapDisplay].to_s) ? input[:heatmapDisplay].to_s : "inline",
          heatmapSpan: %w[1m 3m 6m 12m].include?(input[:heatmapSpan].to_s) ? input[:heatmapSpan].to_s : "6m",
          launchAtLogin: boolean(input[:launchAtLogin], true),
          localGhosttyMode: %w[tab new-window].include?(input[:localGhosttyMode].to_s) ? input[:localGhosttyMode].to_s : "new-window"
        }
      end

      def normalize_local_projects(input)
        input = (input || {}).transform_keys(&:to_sym)
        roots = Array(input[:roots]).map { |path| File.expand_path(path.to_s) }.reject(&:empty?)
        roots = default_local_roots if roots.empty?
        {
          roots: roots.uniq,
          maxDepth: [[positive_int(input[:maxDepth], 4), 1].max, 8].min,
          showDirtyFiles: boolean(input[:showDirtyFiles], true),
          autoSync: boolean(input[:autoSync], false),
          fetchIntervalSeconds: positive_int(input[:fetchIntervalSeconds], 300),
          worktreeFolder: clean(input[:worktreeFolder]) || ".work",
          preferredTerminal: clean(input[:preferredTerminal]) || "kitty"
        }
      end

      def normalize_archives(input)
        input = (input || {}).transform_keys(&:to_sym)
        {
          sources: Array(input[:sources]).filter_map { |source| normalize_archive_source(source) },
          preferArchiveWhenRateLimited: boolean(input[:preferArchiveWhenRateLimited], true),
          staleAfterSeconds: positive_int(input[:staleAfterSeconds], 900)
        }
      end

      def normalize_archive_source(input)
        input = (input || {}).transform_keys(&:to_sym)
        name = clean(input[:name] || input[:id])
        return nil unless name

        {
          id: clean(input[:id]) || name.downcase.gsub(/[^a-z0-9_-]+/, "-"),
          name: name,
          enabled: boolean(input[:enabled], true),
          localRepositoryPath: clean(input[:localRepositoryPath] || input[:repo]),
          remoteURL: clean(input[:remoteURL] || input[:remote]),
          branch: clean(input[:branch]) || "main",
          importedDatabasePath: clean(input[:importedDatabasePath] || input[:db]) || File.join(Dir.home, ".local", "state", "repobar", "archives", "#{name}.sqlite"),
          format: clean(input[:format]) || "discrawlSnapshot"
        }
      end

      def normalize_runtime(input)
        input = (input || {}).transform_keys(&:to_sym)
        {
          refreshSeconds: [positive_int(input[:refreshSeconds], 300), 30].max,
          stateDir: File.expand_path(clean(input[:stateDir]) || File.join(Dir.home, ".local", "state", "repobar")),
          waybarSignal: positive_int(input[:waybarSignal], 10),
          quickShellCommand: clean(input[:quickShellCommand]) || DEFAULT_QUICKSHELL_COMMAND,
          quickShellShell: File.expand_path(clean(input[:quickShellShell]) || default_quickshell_shell)
        }
      end

      def normalize_full_names(values)
        seen = {}
        Array(values).filter_map do |value|
          full_name = clean(value)&.downcase
          next unless full_name&.match?(%r{\A[^/\s]+/[^/\s]+\z})
          next if seen[full_name]

          seen[full_name] = true
          full_name
        end
      end

      def https_host(value)
        text = clean(value)
        text&.start_with?("https://") ? text : nil
      end

      def positive_int(value, default)
        parsed = value.is_a?(Numeric) ? value.to_i : value.to_s.to_i
        parsed.positive? ? parsed : default
      end

      def boolean(value, default)
        return default if value.nil?

        [true, 1, "1", "true", "yes", "on"].include?(value)
      end

      def clean(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def issue(severity, field, message)
        { severity: severity, field: field, message: message }
      end
    end
  end
end
