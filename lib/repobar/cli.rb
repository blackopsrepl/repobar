# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require "zlib"

module RepoBar
  module CLI
    module_function

    def run(argv = ARGV)
      command = argv.first&.start_with?("-") ? "repos" : (argv.shift || "repos")
      args = parse_args(argv)
      config_path = args[:config] || Core::Config.default_config_path

      case command
      when "auth"
        run_auth_command(args, config_path)
      when "status"
        run_auth_command(args, config_path)
      when "login"
        run_login_command(args, config_path)
      when "logout"
        run_logout_command(args, config_path)
      when "config"
        run_config_command(args, config_path)
      when "daemon"
        Runtime::Daemon.run(config_path, once: args[:once])
        0
      when "local"
        run_local_command(args, config_path)
      when "worktrees"
        run_worktrees_command(args, config_path)
      when "checkout"
        run_checkout_command(args, config_path)
      when "cache", "rate-limits"
        run_cache_command(command, args, config_path)
      when "settings"
        run_settings_command(args, config_path)
      when "pin", "unpin", "hide", "show"
        run_repo_visibility_command(command, args, config_path)
      when "archives"
        run_archives_command(args, config_path)
      when "changelog"
        run_changelog_command(args)
      when "markdown"
        run_markdown_command(args)
      when "refresh"
        snapshot = Runtime::Daemon.refresh(config_path)
        print_json(snapshot, args) if args[:format] == "json"
        0
      when "panel"
        Runtime::QuickShell.open(config_path, args[:repo])
        0
      when "ui"
        run_ui_command(args, config_path)
      when "waybar"
        run_waybar_command(args, config_path)
      when "omarchy"
        run_omarchy_command(args, config_path)
      when "open"
        run_open_command(args)
      when "repos"
        run_repos_command(args, config_path)
      when "search"
        run_search_command(args, config_path)
      when "repo", "issues", "pulls", "releases", "ci", "discussions", "tags", "branches", "contributors", "commits", "activity", "contributions"
        run_repo_detail_command(command, args, config_path)
      when "help", "-h", "--help"
        puts help_text
        0
      else
        raise ArgumentError, "Unknown command: #{command}"
      end
    rescue StandardError => e
      warn e.message
      1
    end

    def parse_args(argv)
      args = {
        format: "text",
        pretty: false,
        once: false,
        limit: nil,
        repo: nil,
        root: nil,
        depth: nil,
        yes: false,
        sync: false,
        open: false,
        destination: nil,
        remote: nil,
        branch: nil,
        db: nil,
        sort: nil,
        scope: nil,
        filter: nil,
        only_with: nil,
        owner: nil,
        login: nil,
        include_repos: false,
        release: nil,
        width: nil,
        age: nil,
        forks: false,
        archived: false,
        pinned_only: false,
        no_wrap: false,
        positionals: []
      }
      index = 0
      while index < argv.length
        value = argv[index]
        case value
        when "--config"
          index += 1
          args[:config] = argv[index]
        when "--format"
          index += 1
          args[:format] = argv[index] == "json" ? "json" : "text"
        when "--json", "--json-output", "-j"
          args[:format] = "json"
        when "--pretty"
          args[:pretty] = true
        when "--plain"
          args[:plain] = true
        when "--once"
          args[:once] = true
        when "--limit"
          index += 1
          args[:limit] = argv[index].to_i
        when "--repo"
          index += 1
          args[:repo] = argv[index]
        when "--root"
          index += 1
          args[:root] = argv[index]
        when "--depth"
          index += 1
          args[:depth] = argv[index].to_i
        when "--sync"
          args[:sync] = true
        when "--yes"
          args[:yes] = true
        when "--destination"
          index += 1
          args[:destination] = argv[index]
        when "--remote"
          index += 1
          args[:remote] = argv[index]
        when "--branch"
          index += 1
          args[:branch] = argv[index]
        when "--db"
          index += 1
          args[:db] = argv[index]
        when "--open"
          args[:open] = true
        when "--sort"
          index += 1
          args[:sort] = argv[index]
        when "--age"
          index += 1
          args[:age] = argv[index].to_i
        when "--forks", "--include-forks"
          args[:forks] = true
        when "--archived", "--include-archived"
          args[:archived] = true
        when "--pinned-only"
          args[:pinned_only] = true
        when "--scope"
          index += 1
          args[:scope] = argv[index]
        when "--filter"
          index += 1
          args[:filter] = argv[index]
        when "--only-with"
          index += 1
          args[:only_with] = argv[index]
        when "--owner"
          index += 1
          args[:owner] = argv[index]
        when "--mine"
          args[:mine] = true
        when "--login"
          index += 1
          args[:login] = argv[index]
        when "--include-repos"
          args[:include_repos] = true
        when "--release"
          index += 1
          args[:release] = argv[index] || true
        when "--width"
          index += 1
          args[:width] = argv[index].to_i
        when "--no-wrap"
          args[:no_wrap] = true
        when "--no-color"
          args[:no_color] = true
        when "--after"
          index += 1
          args[:after] = argv[index]
        when "--section"
          index += 1
          args[:section] = argv[index]
        when "--index"
          index += 1
          args[:index] = argv[index]
        when "--interval"
          index += 1
          args[:interval] = argv[index].to_i
        when "--exec"
          index += 1
          args[:exec] = argv[index]
        else
          args[:positionals] << value
        end
        index += 1
      end
      args
    end

    def run_auth_command(args, config_path)
      config = Core::Config.load_config(config_path)
      status = Core::GitHub.auth_status(config)
      if args[:format] == "json"
        print_json(status, args)
      elsif status[:authenticated]
        puts "Authenticated as #{status[:login]} via #{status[:source]}."
        rate = status[:rateLimit] || {}
        puts "GitHub remaining: #{rate[:remaining]} / #{rate[:limit]}" if rate[:remaining]
      else
        puts "Not authenticated: #{status[:error]}"
      end
      status[:authenticated] ? 0 : 1
    end

    def run_login_command(_args, _config_path)
      result = Core::Process.run_command("gh", ["auth", "login"])
      print result.stdout
      warn result.stderr unless result.success?
      result.status
    rescue Errno::ENOENT
      warn "gh is required for GitHub.com login on RepoBar Linux."
      1
    end

    def run_logout_command(_args, _config_path)
      result = Core::Process.run_command("gh", ["auth", "logout"])
      print result.stdout
      warn result.stderr unless result.success?
      result.status
    rescue Errno::ENOENT
      warn "gh is required for GitHub.com logout on RepoBar Linux."
      1
    end

    def run_config_command(args, config_path)
      subcommand = args[:positionals].first || "validate"
      if subcommand == "init"
        config = Core::Config.init_config(config_path)
        print_json(config, args)
        return 0
      end

      config = Core::Config.load_config(config_path)
      issues = Core::Config.validate_config(config)
      if args[:format] == "json"
        print_json(issues, args)
      elsif issues.empty?
        puts "Config valid."
      else
        issues.each { |issue| puts "#{issue[:severity].upcase}: #{issue[:field]} #{issue[:message]}" }
      end
      issues.any? { |issue| issue[:severity] == "error" } ? 1 : 0
    end

    def run_local_command(args, config_path)
      config = Core::Config.load_config(config_path)
      subcommand = args[:positionals].first
      return run_local_action(subcommand, args, config) if %w[sync rebase reset branches].include?(subcommand)

      if args[:root]
        config = Core::Config.normalize_config(config.merge(localProjects: config[:localProjects].merge(roots: [args[:root]])))
      end
      if args[:depth].to_i.positive?
        config = Core::Config.normalize_config(config.merge(localProjects: config[:localProjects].merge(maxDepth: args[:depth])))
      end
      local = Core::LocalGit.scan(config)
      local = local.first(args[:limit]) if args[:limit].to_i.positive?
      sync_results = []
      sync_results = local.select { |repo| !repo[:dirty] && repo[:behind].to_i.positive? }.map { |repo| Core::LocalGit.sync(repo[:path]) } if args[:sync]
      if args[:format] == "json"
        print_json({ repositories: local, synced: sync_results }, args)
      else
        local.each do |repo|
          dirty = repo[:dirty] ? " dirty=#{repo[:dirtyCount]}" : ""
          puts "#{repo[:fullName] || File.basename(repo[:path])} #{repo[:branch]}#{dirty} #{repo[:path]}"
        end
        puts "Synced #{sync_results.length} repos." if args[:sync]
      end
      0
    end

    def run_local_action(subcommand, args, config)
      target = args[:positionals][1]
      path = Core::LocalGit.resolve_target(config, target)
      payload = case subcommand
                when "sync" then Core::LocalGit.sync(path)
                when "rebase" then Core::LocalGit.rebase(path)
                when "reset"
                  raise ArgumentError, "Refusing hard reset without --yes." unless args[:yes]

                  Core::LocalGit.hard_reset(path)
                when "branches" then { path: path, branches: Core::LocalGit.branches(path) }
                end
      args[:format] == "json" ? print_json(payload, args) : puts(local_action_text(subcommand, payload))
      0
    end

    def local_action_text(subcommand, payload)
      return payload[:branches].map { |branch| "#{branch[:current] ? '*' : ' '} #{branch[:name]} #{branch[:sha]} #{branch[:updatedAt]}" }.join("\n") if subcommand == "branches"

      "#{subcommand} #{payload[:path]} ok"
    end

    def run_worktrees_command(args, config_path)
      config = Core::Config.load_config(config_path)
      path = Core::LocalGit.resolve_target(config, args[:positionals].first)
      payload = { path: path, worktrees: Core::LocalGit.worktrees(path) }
      args[:format] == "json" ? print_json(payload, args) : payload[:worktrees].each { |tree| puts "#{tree[:branch] || 'detached'} #{tree[:sha]} #{tree[:path]}" }
      0
    end

    def run_checkout_command(args, config_path)
      config = Core::Config.load_config(config_path)
      full_name = args[:positionals].first
      raise ArgumentError, "Repository required as owner/name." unless full_name.to_s.match?(%r{\A[^/\s]+/[^/\s]+\z})

      payload = Core::LocalGit.clone(config, full_name, destination: args[:destination])
      Core::Process.spawn_detached("xdg-open", [payload[:path]]) if args[:open]
      args[:format] == "json" ? print_json(payload, args) : puts("Cloned #{payload[:fullName]} to #{payload[:path]}")
      0
    end

    def run_repos_command(args, config_path)
      config = Core::Config.load_config(config_path)
      repos = scoped_repositories(config, config_path, args)
      repos = filter_repos(repos, args, config)
      repos = repos.first(args[:limit]) if args[:limit].to_i.positive?
      if args[:format] == "json"
        print_json(repos, args)
      else
        repos.each { |repo| puts Core::Format.repo_line(repo) }
      end
      0
    end

    def run_search_command(args, config_path)
      subcommand = args[:positionals].first.to_s
      if subcommand == "select"
        state = Runtime::Daemon.dispatch_action(config_path, type: "search_select", fullName: args[:positionals][1])
        args[:format] == "json" ? print_json(state, args) : puts("Selected #{state[:selectedFullName]}.")
        return 0
      end

      query = args[:positionals].join(" ")
      limit = args[:limit].to_i.positive? ? args[:limit].to_i : 10
      state = Runtime::Daemon.dispatch_action(config_path, type: "search_start", query: query, limit: limit)
      if args[:format] == "json"
        print_json(state, args)
      else
        puts "Searching #{state[:query]}."
      end
      0
    end

    def scoped_repositories(config, config_path, args)
      if args[:scope] == "pinned" || args[:pinned_only]
        return hydrated_named_repositories(config, Array(config.dig(:repoList, :pinnedRepositories)))
      end
      return hydrated_named_repositories(config, Array(config.dig(:repoList, :hiddenRepositories))) if args[:scope] == "hidden"

      if args[:forks] || args[:archived]
        effective = Core::Config.normalize_config(
          config.merge(repoList: config[:repoList].merge(showForks: args[:forks] || config.dig(:repoList, :showForks), showArchived: args[:archived] || config.dig(:repoList, :showArchived)))
        )
        return Core::GitHub.fetch_repositories(effective)
      end

      snapshot = Runtime::State.read_snapshot(config)
      snapshot ||= Runtime::Daemon.refresh(config_path, config: config)
      Array(snapshot[:repositories])
    end

    def hydrated_named_repositories(config, names)
      token = Core::GitHub.access_token(config)
      names.filter_map { |full_name| Core::GitHub.repository(config, token, full_name) }
        .map { |repo| Core::GitHub.hydrate_repository(config, token, repo) }
    end

    def run_repo_detail_command(command, args, config_path)
      config = Core::Config.load_config(config_path)
      full_name = args[:positionals].first || args[:repo]
      if %w[commits activity contributions].include?(command)
        full_name ||= args[:login] || auth_login(config)
      else
        raise ArgumentError, "Repository required as owner/name." unless full_name.to_s.match?(%r{\A[^/\s]+/[^/\s]+\z})
      end

      token = Core::GitHub.access_token(config)
      limit = args[:limit].to_i.positive? ? args[:limit].to_i : 20
      case command
      when "repo"
        repo = Core::GitHub.hydrate_repository(config, token, Core::GitHub.repository(config, token, full_name))
        output_repo_detail(repo, args)
      when "issues"
        owner, name = full_name.split("/", 2)
        output_rows(Core::GitHub.issues(config, token, owner, name, limit), args) { |item| "##{item[:number]} #{item[:title]} @#{item[:author]} #{item[:updatedAt]}" }
      when "pulls"
        owner, name = full_name.split("/", 2)
        output_rows(Core::GitHub.pulls(config, token, owner, name, limit), args) { |item| "##{item[:number]} #{item[:draft] ? '[draft] ' : ''}#{item[:title]} @#{item[:author]} #{item[:updatedAt]}" }
      when "releases"
        owner, name = full_name.split("/", 2)
        output_rows(Core::GitHub.releases(config, token, owner, name, limit), args) { |item| "#{item[:tag]} #{item[:name]} #{item[:publishedAt]}" }
      when "ci"
        owner, name = full_name.split("/", 2)
        output_rows(Core::GitHub.workflow_runs(config, token, owner, name, limit), args) { |item| "#{item[:status]} #{item[:name]} #{item[:updatedAt]}" }
      when "discussions"
        owner, name = full_name.split("/", 2)
        output_rows(Core::GitHub.discussions(config, token, owner, name, limit), args) { |item| "##{item[:number]} #{item[:title]} @#{item[:author]} #{item[:comments]} comments #{item[:updatedAt]}" }
      when "tags"
        owner, name = full_name.split("/", 2)
        output_rows(Core::GitHub.tags(config, token, owner, name, limit), args) { |item| "#{item[:name]} #{item[:sha]}" }
      when "branches"
        owner, name = full_name.split("/", 2)
        output_rows(Core::GitHub.branches(config, token, owner, name, limit), args) { |item| "#{item[:name]} #{item[:sha]}#{item[:protected] ? ' protected' : ''}" }
      when "contributors"
        owner, name = full_name.split("/", 2)
        output_rows(Core::GitHub.contributors(config, token, owner, name, limit), args) { |item| "#{item[:login]} #{item[:contributions]}" }
      when "commits"
        if full_name.include?("/")
          owner, name = full_name.split("/", 2)
          output_rows(Core::GitHub.commits(config, token, owner, name, limit), args) { |item| "#{item[:sha].to_s[0, 8]} #{item[:author]} #{Core::Format.relative_time(item[:date])} #{item[:message].to_s.lines.first&.chomp}" }
        else
          output_rows(Core::GitHub.global_activity(config, token, full_name, limit), args) { |item| "#{item[:date]} #{item[:repo]} #{item[:title]}" }
        end
      when "activity"
        if full_name.include?("/")
          owner, name = full_name.split("/", 2)
          output_rows(Core::GitHub.recent_activity(config, token, owner, name, limit), args) { |item| "#{item[:date]} #{item[:actor]} #{item[:title]}" }
        else
          output_rows(Core::GitHub.global_activity(config, token, args[:login] || full_name, limit), args) { |item| "#{item[:date]} #{item[:repo]} #{item[:actor]} #{item[:title]}" }
        end
      when "contributions"
        login = args[:login] || full_name
        payload = { login: login, imageUrl: "https://ghchart.rshah.org/#{login}" }
        args[:format] == "json" ? print_json(payload, args) : puts(payload[:imageUrl])
      end
      0
    end

    def auth_login(config)
      Core::GitHub.auth_status(config)[:login].to_s
    end

    def output_rows(rows, args)
      if args[:format] == "json"
        print_json(rows, args)
      elsif rows.empty?
        puts "No rows."
      else
        rows.each { |item| puts yield(item) }
      end
    end

    def filter_repos(repos, args, config = nil)
      output = repos
      output = output.reject { |repo| repo[:fork] } unless args[:forks]
      output = output.reject { |repo| repo[:archived] } unless args[:archived]
      if args[:age].to_i.positive?
        cutoff = Time.now - (args[:age].to_i * 86_400)
        output = output.select do |repo|
          time = Core::Format.parse_time(repo.dig(:stats, :pushedAt) || repo[:updatedAt])
          time && time >= cutoff
        end
      end
      output = output.select { |repo| repo[:owner].to_s.casecmp?(auth_login(config || Core::Config.default_config)) } if args[:mine]
      output = output.select { |repo| repo[:owner].to_s.casecmp?(args[:owner]) } if args[:owner].to_s != ""
      case args[:only_with] || args[:filter]
      when "work"
        output = output.select { |repo| repo.dig(:stats, :openIssues).to_i.positive? || repo.dig(:stats, :openPulls).to_i.positive? }
      when "issues"
        output = output.select { |repo| repo.dig(:stats, :openIssues).to_i.positive? }
      when "prs"
        output = output.select { |repo| repo.dig(:stats, :openPulls).to_i.positive? }
      end
      case args[:sort]
      when "issues", "prs", "stars", "repo"
        Core::GitHub.sort_repositories(output, args[:sort])
      else
        output
      end
    end

    def output_repo_detail(repo, args)
      if args[:format] == "json"
        print_json(repo, args)
      else
        puts Core::Format.repo_line(repo)
        puts repo[:description] if repo[:description].to_s != ""
        puts "URL: #{repo[:url]}"
      end
    end

    def output_simple_count(label, count, args)
      args[:format] == "json" ? print_json({ label: label, count: count }, args) : puts("#{count} #{label}")
    end

    def run_ui_command(args, config_path)
      subcommand = args[:positionals].first || "open"
      payload = case subcommand
                when "open" then Runtime::QuickShell.open(config_path, args[:repo] || args[:positionals][1])
                when "triage" then Runtime::QuickShell.open(config_path, args[:repo] || args[:positionals][1], mode: "triage")
                when "mode"
                  mode = args[:positionals][1].to_s
                  raise ArgumentError, "mode must be overview or triage." unless %w[overview triage].include?(mode)

                  Runtime::Store.open_panel(config_path, args[:repo] || args[:positionals][2], mode: mode)
                when "close" then Runtime::QuickShell.close(config_path)
                when "toggle" then Runtime::QuickShell.toggle(config_path, args[:repo] || args[:positionals][1])
                when "status" then Runtime::QuickShell.status(config_path)
                else raise ArgumentError, "Unknown ui subcommand: #{subcommand}"
                end
      args[:format] == "json" ? print_json(payload, args) : puts(JSON.generate(payload))
      0
    end

    def run_waybar_command(args, config_path)
      subcommand = args[:positionals].first || "render"
      case subcommand
      when "render"
        Runtime::Waybar.render(config_path)
      when "refresh"
        Runtime::Daemon.dispatch_action(config_path, type: "refresh")
      when "panel", "open"
        Runtime::QuickShell.open(config_path)
      else
        raise ArgumentError, "Unknown waybar subcommand: #{subcommand}"
      end
      0
    end

    def run_omarchy_command(args, config_path)
      subcommand = args[:positionals].first || "status"
      result = case subcommand
               when "install"
                 Runtime::Omarchy.install(
                   after: args[:after],
                   section: args[:section],
                   index: args[:index],
                   interval: args[:interval] || Runtime::Omarchy::DEFAULT_INTERVAL,
                   bin: args[:exec],
                   config_path: config_path
                 )
               when "remove"
                 Runtime::Omarchy.remove
               when "status"
                 Runtime::Omarchy.status
               else
                 raise ArgumentError, "Unknown omarchy subcommand: #{subcommand}"
               end
      print_json(result, args) if args[:format] == "json"
      puts describe_omarchy_result(subcommand, result) unless args[:format] == "json"
      0
    end

    def describe_omarchy_result(subcommand, result)
      case subcommand
      when "install"
        "Installed #{Runtime::Omarchy::MODULE_ID} module in #{result[:shellConfig]} " \
          "(#{result[:section]}[#{result[:index]}], seeded from #{result[:seededFrom]})"
      when "remove"
        result[:removed] ? "Removed #{Runtime::Omarchy::MODULE_ID} module from #{result[:shellConfig]}" : result[:reason]
      else
        if result[:installed]
          "#{Runtime::Omarchy::MODULE_ID} module installed at #{result[:shellConfig]} " \
            "(#{result[:section]}[#{result[:index]}])"
        else
          "#{Runtime::Omarchy::MODULE_ID} module not installed"
        end
      end
    end

    def run_open_command(args)
      subcommand = args[:positionals].first
      if %w[finder terminal].include?(subcommand)
        config = Core::Config.load_config(args[:config] || Core::Config.default_config_path)
        path = Core::LocalGit.resolve_target(config, args[:positionals][1])
        command = subcommand == "terminal" ? config.dig(:localProjects, :preferredTerminal) : "xdg-open"
        return Core::Process.spawn_detached(command, [path])
      end

      target = subcommand
      raise ArgumentError, "Open target required." if target.to_s.strip.empty?

      Core::Process.spawn_detached("xdg-open", [target])
      0
    end

    def run_repo_visibility_command(command, args, config_path)
      if command == "pin" && args[:positionals].first == "move"
        full_name = args[:positionals][1]
        position = args[:positionals][2]
        raise ArgumentError, "pin move requires owner/name and zero-based position." unless full_name.to_s.match?(%r{\A[^/\s]+/[^/\s]+\z}) && position.to_s.match?(/\A\d+\z/)

        repo_list = Runtime::Daemon.dispatch_action(config_path, type: "pin_move", fullName: full_name, position: position.to_i)
        args[:format] == "json" ? print_json(repo_list, args) : puts("moved #{full_name.to_s.downcase} to #{position.to_i + 1}")
        return 0
      end

      full_name = args[:positionals].first
      repo_list = case command
                  when "pin" then Runtime::Daemon.dispatch_action(config_path, type: "pin", fullName: full_name)
                  when "unpin" then Runtime::Daemon.dispatch_action(config_path, type: "unpin", fullName: full_name)
                  when "hide" then Runtime::Daemon.dispatch_action(config_path, type: "hide", fullName: full_name)
                  when "show" then Runtime::Daemon.dispatch_action(config_path, type: "show", fullName: full_name)
                  end
      args[:format] == "json" ? print_json(repo_list, args) : puts("#{command} #{full_name.to_s.downcase}")
      0
    end

    def run_settings_command(args, config_path)
      subcommand = args[:positionals].first || "show"
      config = Core::Config.load_config(config_path)
      if subcommand == "show"
        args[:format] == "json" ? print_json(config, args) : puts(JSON.pretty_generate(config))
        return 0
      end
      raise ArgumentError, "Unknown settings subcommand: #{subcommand}" unless subcommand == "set"

      key = args[:positionals][1]
      value = args[:positionals][2]
      raise ArgumentError, "settings set requires key and value." if key.to_s.empty? || value.to_s.empty?

      update_setting(config, key, value)
      saved = Core::Config.save_config(config, config_path)
      args[:format] == "json" ? print_json(saved, args) : puts("Updated #{key}.")
      0
    end

    def update_setting(config, key, value)
      case key
      when "refresh-interval" then config[:runtime][:refreshSeconds] = duration_seconds(value)
      when "repo-limit" then config[:repoList][:displayLimit] = value.to_i
      when "show-forks" then config[:repoList][:showForks] = truthy?(value)
      when "show-archived" then config[:repoList][:showArchived] = truthy?(value)
      when "menu-sort" then config[:repoList][:menuSort] = value
      when "show-contribution-header" then config[:settings][:showContributionHeader] = truthy?(value)
      when "show-rate-limit-meter" then config[:settings][:showRateLimitMeter] = truthy?(value)
      when "card-density" then config[:settings][:cardDensity] = value
      when "accent-tone" then config[:settings][:accentTone] = value
      when "activity-scope" then config[:settings][:activityScope] = value
      when "heatmap-display" then config[:settings][:heatmapDisplay] = value
      when "heatmap-span" then config[:settings][:heatmapSpan] = value
      when "launch-at-login" then config[:settings][:launchAtLogin] = truthy?(value)
      when "local-root" then config[:localProjects][:roots] = [File.expand_path(value)]
      when "local-auto-sync" then config[:localProjects][:autoSync] = truthy?(value)
      when "local-fetch-interval" then config[:localProjects][:fetchIntervalSeconds] = duration_seconds(value)
      when "local-worktree-folder" then config[:localProjects][:worktreeFolder] = value
      when "local-preferred-terminal" then config[:localProjects][:preferredTerminal] = value
      when "local-ghostty-mode" then config[:settings][:localGhosttyMode] = value
      when "local-show-dirty-files" then config[:localProjects][:showDirtyFiles] = truthy?(value)
      else
        config[:settings] ||= {}
        config[:settings][key.to_sym] = value
      end
    end

    def run_cache_command(command, args, config_path)
      config = Core::Config.load_config(config_path)
      subcommand = command == "rate-limits" ? "rate-limits" : args[:positionals].first || "status"
      snapshot = Runtime::State.read_snapshot(config)
      payload = Core::Cache.summary(config, limit: args[:limit].to_i.positive? ? args[:limit].to_i : 10).merge(
        stateDir: Runtime::State.state_dir(config),
        snapshotPath: Runtime::State.snapshot_path(config),
        snapshotExists: !snapshot.nil?,
        generatedAt: snapshot && snapshot[:generatedAt],
        repositoryCount: Array(snapshot && snapshot[:repositories]).length,
        rateLimit: snapshot && snapshot.dig(:account, :rateLimit)
      )
      if subcommand == "clear"
        payload = Core::Cache.clear(config).merge(cleared: true)
      end
      args[:format] == "json" ? print_json(payload, args) : puts(JSON.pretty_generate(payload))
      0
    end

    def run_archives_command(args, config_path)
      subcommand = args[:positionals].first || "list"
      name = args[:positionals][1]
      config = Core::Config.load_config(config_path)
      archives = config[:archives]
      case subcommand
      when "list"
        payload = archives
      when "add"
        source = { name: name, localRepositoryPath: args[:repo], remoteURL: args[:remote], branch: args[:branch] || "main", importedDatabasePath: args[:db] }.compact
        archives[:sources] << Core::Config.normalize_archive_source(source)
        payload = Core::Config.save_config(config, config_path)[:archives]
      when "remove"
        archives[:sources].delete_if { |source| source[:name].casecmp?(name.to_s) || source[:id] == name }
        payload = Core::Config.save_config(config, config_path)[:archives]
      when "enable", "disable"
        enabled = subcommand == "enable"
        archives[:sources].each { |source| source[:enabled] = enabled if source[:name].casecmp?(name.to_s) || source[:id] == name }
        payload = Core::Config.save_config(config, config_path)[:archives]
      when "status", "validate"
        payload = archives[:sources].select { |source| name.to_s.empty? || source[:name].casecmp?(name.to_s) || source[:id] == name }.map { |source| archive_status(source) }
      when "update"
        source = archives[:sources].find { |item| item[:name].casecmp?(name.to_s) || item[:id] == name }
        raise ArgumentError, "Archive not found: #{name}" unless source

        payload = update_archive(config, source)
      else
        raise ArgumentError, "Unknown archives subcommand: #{subcommand}"
      end
      args[:format] == "json" ? print_json(payload, args) : puts(JSON.pretty_generate(payload))
      0
    end

    def archive_status(source)
      repo_path = source[:localRepositoryPath] && File.expand_path(source[:localRepositoryPath])
      db_path = source[:importedDatabasePath] && File.expand_path(source[:importedDatabasePath])
      {
        id: source[:id],
        name: source[:name],
        enabled: source[:enabled],
        repoExists: repo_path ? Dir.exist?(repo_path) : false,
        databaseExists: db_path ? File.file?(db_path) : false,
        localRepositoryPath: repo_path,
        importedDatabasePath: db_path,
        configValid: !!(source[:remoteURL] || source[:localRepositoryPath])
      }
    end

    def update_archive(config, source)
      source[:localRepositoryPath] ||= File.join(config.dig(:runtime, :stateDir), "archives", "snapshots", source[:id]) if source[:remoteURL]
      repo_path = File.expand_path(source[:localRepositoryPath].to_s)
      if source[:remoteURL] && !Dir.exist?(repo_path)
        FileUtils.mkdir_p(File.dirname(repo_path))
        Core::Process.run_text("git", ["clone", "--branch", source[:branch], source[:remoteURL], repo_path])
      elsif Dir.exist?(File.join(repo_path, ".git"))
        Core::Process.run_command("git", ["-C", repo_path, "pull", "--ff-only"])
      end

      manifest_path = File.join(repo_path, "manifest.json")
      raise ArgumentError, "Archive manifest not found: #{manifest_path}" unless File.file?(manifest_path)

      manifest = JSON.parse(File.read(manifest_path))
      db_path = File.expand_path(source[:importedDatabasePath])
      FileUtils.mkdir_p(File.dirname(db_path))
      sql = archive_import_sql(repo_path, manifest)
      result = Core::Process.run_command("sqlite3", [db_path], stdin_data: sql)
      raise "sqlite3 import failed: #{result.stderr}" unless result.success?

      archive_status(source).merge(updated: true, tables: Array(manifest["tables"]).length, importedDatabasePath: db_path)
    end

    def archive_import_sql(repo_path, manifest)
      statements = ["BEGIN;", "PRAGMA user_version = 1;"]
      Array(manifest["tables"]).each do |table|
        table_name = safe_sql_name(table["name"])
        rows = archive_rows(repo_path, table)
        columns = archive_columns(table, rows)
        statements << "DROP TABLE IF EXISTS #{table_name};"
        statements << "CREATE TABLE #{table_name} (#{columns.map { |column| "#{safe_sql_name(column)} TEXT" }.join(', ')});"
        rows.each do |row|
          statements << "INSERT INTO #{table_name} (#{columns.map { |column| safe_sql_name(column) }.join(', ')}) VALUES (#{columns.map { |column| sql_quote(row[column]) }.join(', ')});"
        end
      end
      statements << "CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, value TEXT);"
      statements << "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('repobar:last_import', #{sql_quote(Time.now.utc.iso8601)});"
      statements << "COMMIT;"
      statements.join("\n")
    end

    def archive_rows(repo_path, table)
      Array(table["files"]).flat_map do |file|
        path = File.join(repo_path, file)
        next [] unless File.file?(path)

        text = path.end_with?(".gz") ? Zlib::GzipReader.open(path, &:read) : File.read(path)
        text.lines.filter_map { |line| line.strip.empty? ? nil : JSON.parse(line) }
      end
    end

    def archive_columns(table, rows)
      explicit = Array(table["columns"]).map { |column| column.is_a?(Hash) ? column["name"] : column }.compact
      explicit.empty? ? rows.flat_map(&:keys).uniq : explicit
    end

    def safe_sql_name(name)
      %("#{name.to_s.gsub(/[^a-zA-Z0-9_]/, "_")}")
    end

    def sql_quote(value)
      return "NULL" if value.nil?

      "'#{value.is_a?(String) ? value.gsub("'", "''") : JSON.generate(value).gsub("'", "''")}'"
    end

    def run_changelog_command(args)
      path = args[:positionals].first || %w[CHANGELOG.md CHANGELOG].find { |candidate| File.file?(candidate) }
      raise ArgumentError, "Missing changelog file." unless path && File.file?(path)

      sections = File.read(path).lines.select { |line| line.match?(/\A#{Regexp.escape("#")}+\s+/) }.map { |line| line.sub(/\A#+\s*/, "").strip }
      payload = { path: path, sections: sections, release: args[:release] }
      args[:format] == "json" ? print_json(payload, args) : sections.each { |section| puts section }
      0
    end

    def run_markdown_command(args)
      path = args[:positionals].first
      raise ArgumentError, "Markdown path required." unless path && File.file?(path)

      text = File.read(path)
        .gsub(/\A---\n.*?\n---\n/m, "")
        .gsub(/`([^`]+)`/, "\\1")
        .gsub(/\*\*([^*]+)\*\*/, "\\1")
        .gsub(/\[([^\]]+)\]\([^)]+\)/, "\\1")
      puts text
      0
    end

    def duration_seconds(value)
      text = value.to_s
      return text.to_i * 60 if text.end_with?("m")
      return text.to_i * 3600 if text.end_with?("h")

      text.to_i
    end

    def truthy?(value)
      [true, 1, "1", "true", "yes", "on"].include?(value)
    end

    def print_json(payload, args)
      puts(args[:pretty] ? JSON.pretty_generate(payload) : JSON.generate(payload))
    end

    def help_text
      <<~TEXT
        RepoBar Linux

        Commands:
          repobar auth status
          repobar config init|validate
          repobar repos [--format json] [--limit N]
          repobar search query [--format json]
          repobar repo owner/name
          repobar issues owner/name
          repobar pulls owner/name
          repobar releases owner/name
          repobar ci owner/name
          repobar tags|branches|contributors owner/name
          repobar commits|activity [owner/name|login]
          repobar local [--root PATH] [--sync]
          repobar local sync|rebase|branches <path|owner/name>
          repobar local reset <path|owner/name> --yes
          repobar worktrees <path|owner/name>
          repobar checkout owner/name
          repobar pin|unpin|hide|show owner/name
          repobar pin move owner/name POSITION
          repobar settings show|set
          repobar cache status|clear
          repobar rate-limits
          repobar archives list|status|validate|add|remove|enable|disable|update
          repobar changelog [path]
          repobar markdown path
          repobar open URL
          repobar refresh [--format json]
          repobar daemon [--once]
          repobar panel
          repobar ui open|close|toggle|status
          repobar waybar render|refresh|panel
          repobar omarchy install|remove|status
      TEXT
    end
  end
end
