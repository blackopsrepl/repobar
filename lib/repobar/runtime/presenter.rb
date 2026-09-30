# frozen_string_literal: true

require "date"

module RepoBar
  module Runtime
    module Presenter
      module_function

      def build_snapshot_view(config, snapshot, now = Time.now)
        repos = Array(snapshot[:repositories])
        summary = summary_view(config, snapshot, repos, now)
        repo_views = repos.map { |repo| repo_view(config, repo, now) }
        {
          summary: summary,
          accountHeatmap: account_heatmap_view(snapshot.dig(:account, :heatmap)),
          chip: chip_view(summary, repos),
          repositories: repo_views,
          localRepositories: Array(snapshot[:localRepositories]),
          triage: triage_view(repo_views)
        }
      end

      # Cross-repository work queue for the triage mode. One flat, newest-first
      # inbox built entirely from the cached snapshot so the UI never blocks on
      # the network. README-style separators come from this projection too.
      def triage_view(repo_views)
        items = repo_views.flat_map do |repo|
          Array(repo[:pulls]).map { |item| triage_item(repo, item, "pr") } +
            Array(repo[:issues]).map { |item| triage_item(repo, item, "issue") }
        end
        items.sort_by! { |item| item[:updatedAt].to_s }
        items.reverse!
        {
          total: items.length,
          pullCount: items.count { |item| item[:kind] == "pr" },
          issueCount: items.count { |item| item[:kind] == "issue" },
          items: items
        }
      end

      def triage_item(repo, item, kind)
        {
          id: "#{repo[:fullName].to_s.downcase}##{item[:number]}",
          kind: kind,
          repoFullName: repo[:fullName],
          owner: repo[:owner],
          ownerAvatarUrl: repo[:ownerAvatarUrl],
          number: item[:number],
          title: item[:title],
          author: item[:author],
          draft: !!item[:draft],
          updatedAt: item[:updatedAt],
          updatedText: item[:updatedText],
          url: item[:url],
          labels: item[:labels],
          comments: item[:comments].to_i,
          reviewComments: item[:reviewComments].to_i,
          body: item[:body],
          bodyFull: item[:bodyFull]
        }
      end

      def summary_view(_config, snapshot, repos, now)
        stale = State.stale?(snapshot, snapshot[:config], now)
        errors = repos.count { |repo| repo[:error].to_s != "" }
        ci_failures = repos.count { |repo| repo[:ciStatus] == "failing" }
        dirty = repos.count { |repo| repo.dig(:local, :dirty) }
        open_prs = repos.sum { |repo| repo.dig(:stats, :openPulls).to_i }
        open_issues = repos.sum { |repo| repo.dig(:stats, :openIssues).to_i }
        rate = snapshot.dig(:account, :rateLimit) || {}
        provider = snapshot.dig(:account, :provider) || snapshot.dig(:config, :provider) || "github"
        {
          provider: provider.to_s == "forgejo" ? "forgejo" : "github",
          providerLabel: provider.to_s == "forgejo" ? "FJ" : "GH",
          repoCount: repos.length,
          openPulls: open_prs,
          openIssues: open_issues,
          ciFailures: ci_failures,
          dirtyRepos: dirty,
          errorCount: errors,
          stale: stale,
          account: snapshot.dig(:account, :login),
          rateLimitRemaining: rate[:remaining],
          rateLimitResetAt: rate[:resetAt],
          updatedText: Core::Format.relative_time(snapshot[:generatedAt], now)
        }
      end

      def chip_view(summary, repos)
        classes = ["repobar"]
        classes << "stale" if summary[:stale]
        classes << "error" if summary[:errorCount].positive?
        classes << "has-ci-failures" if summary[:ciFailures].positive?
        classes << "local-dirty" if summary[:dirtyRepos].positive?
        classes << "has-work" if summary[:openPulls].positive? || summary[:openIssues].positive?
        classes << "rate-limited" if summary[:rateLimitRemaining].to_i < 100 && !summary[:rateLimitRemaining].nil?
        classes << "healthy" if classes == ["repobar"]

        work = []
        work << "#{summary[:openPulls]} PR" if summary[:openPulls].positive?
        work << "#{summary[:openIssues]} issue" if summary[:openIssues].positive?
        work << "#{summary[:dirtyRepos]} dirty" if summary[:dirtyRepos].positive?
        work << "#{summary[:ciFailures]} CI" if summary[:ciFailures].positive?
        label = summary[:providerLabel] || "GH"
        text = work.empty? ? "#{label} #{summary[:repoCount]} repos" : "#{label} #{work.first(2).join(' ')}"

        tooltip = [
          "RepoBar",
          "Provider: #{summary[:provider] == 'forgejo' ? 'Forgejo' : 'GitHub'}",
          "Account: #{summary[:account] || 'not authenticated'}",
          "Repos: #{summary[:repoCount]}",
          "Open PRs: #{summary[:openPulls]}",
          "Open issues: #{summary[:openIssues]}",
          "Dirty local repos: #{summary[:dirtyRepos]}",
          "CI failures: #{summary[:ciFailures]}",
          summary[:rateLimitRemaining] ? "GitHub remaining: #{summary[:rateLimitRemaining]}" : nil,
          "Updated: #{summary[:updatedText]}",
          "",
          *repos.first(8).map { |repo| "#{repo[:fullName]}: #{repo.dig(:stats, :openPulls)} PR / #{repo.dig(:stats, :openIssues)} issues / #{repo[:ciStatus]}" }
        ].compact.join("\n")

        { text: text, tooltipLines: tooltip.split("\n"), classes: classes.uniq }
      end

      def repo_view(config, repo, now = Time.now)
        stats = repo.fetch(:stats, {})
        local = repo[:local]
        full_name = repo[:fullName].to_s.downcase
        pinned = Array(config.dig(:repoList, :pinnedRepositories)).include?(full_name)
        {
          fullName: repo[:fullName],
          name: repo[:name],
          owner: repo[:owner],
          ownerAvatarUrl: repo[:ownerAvatarUrl],
          ownerUrl: repo[:ownerUrl],
          description: repo[:description],
          url: repo[:url],
          private: repo[:private],
          archived: repo[:archived],
          fork: repo[:fork],
          pinned: pinned,
          stars: stats[:stars].to_i,
          forks: stats[:forks].to_i,
          openIssues: stats[:openIssues].to_i,
          openPulls: stats[:openPulls].to_i,
          pushedText: Core::Format.relative_time(stats[:pushedAt] || repo[:updatedAt], now),
          ciStatus: repo[:ciStatus] || "unknown",
          latestRelease: repo[:latestRelease],
          latestActivity: repo[:latestActivity],
          issues: readable_items(repo[:issues], now),
          pulls: readable_items(repo[:pulls], now),
          traffic: repo[:traffic],
          heatmap: heatmap_view(repo[:heatmap]),
          local: local,
          pending: !!repo[:pending],
          status: repo_status(repo),
          error: repo[:error]
        }
      end

      def account_heatmap_view(heatmap)
        return nil unless heatmap

        max = (heatmap && heatmap[:max]).to_i
        weeks = Array(heatmap[:weeks]).map { |week| account_heatmap_week(week, max) }
        weeks = account_heatmap_weeks_from_cells(Array(heatmap[:cells]), max) if weeks.empty?
        {
          available: heatmap[:available] != false,
          total: heatmap[:total].to_i,
          max: max,
          weeks: weeks,
          rows: account_heatmap_rows(weeks),
          cells: weeks.flat_map { |week| week[:cells] },
          stats: account_heatmap_stats(weeks)
        }
      end

      def heatmap_view(heatmap)
        cells = Array(heatmap && heatmap[:cells])
        cells = empty_heatmap_cells if cells.empty?
        max = (heatmap && heatmap[:max]).to_i
        {
          total: (heatmap && heatmap[:total]).to_i,
          max: max,
          cells: cells.last(42).map do |cell|
            count = cell[:count].to_i
            {
              date: cell[:date],
              count: count,
              intensity: max.positive? ? ((count.to_f / max) * 4).ceil : 0
            }
          end
        }
      end

      def account_heatmap_week(week, max)
        cells = Array(week[:cells])
        by_day = cells.to_h do |cell|
          date = Date.parse(cell[:date].to_s)
          [date.wday, heatmap_cell(cell, max)]
        rescue ArgumentError
          [nil, nil]
        end
        {
          cells: (0...7).map { |day| by_day[day] || empty_heatmap_cell }
        }
      end

      def account_heatmap_weeks_from_cells(cells, max)
        days = cells.map { |cell| heatmap_cell(cell, max) }
        days.each_slice(7).map do |slice|
          { cells: slice.fill(empty_heatmap_cell, slice.length...7) }
        end
      end

      def account_heatmap_rows(weeks)
        (0...7).map do |day|
          {
            cells: weeks.map { |week| Array(week[:cells])[day] || empty_heatmap_cell }
          }
        end
      end

      def account_heatmap_stats(weeks)
        cells = weeks.flat_map { |week| Array(week[:cells]) }.reject { |cell| cell[:empty] }
        dated = cells.select { |cell| cell[:date].to_s != "" }.sort_by { |cell| cell[:date].to_s }
        best = dated.max_by { |cell| [cell[:count].to_i, cell[:date].to_s] }
        best_count = best ? best[:count].to_i : 0

        {
          activeDays: dated.count { |cell| cell[:count].to_i.positive? },
          currentStreak: current_heatmap_streak(dated),
          bestCount: best_count,
          bestDay: best_count.positive? ? best[:date] : nil,
          bestDayText: best_count.positive? ? heatmap_date_text(best[:date]) : "none"
        }
      end

      def current_heatmap_streak(dated_cells)
        streak = 0
        dated_cells.reverse_each do |cell|
          count = cell[:count].to_i
          if count.positive?
            streak += 1
          else
            break
          end
        end
        streak
      end

      def heatmap_date_text(value)
        Date.parse(value.to_s).strftime("%b %e").strip
      rescue ArgumentError
        value.to_s
      end

      def heatmap_cell(cell, max)
        count = cell[:count].to_i
        {
          date: cell[:date],
          count: count,
          intensity: max.positive? ? ((count.to_f / max) * 4).ceil : 0
        }
      end

      def readable_items(items, now)
        Array(items).first(20).map { |item| readable_item(item, now) }
      end

      def readable_item(item, now)
        {
          number: item[:number],
          title: item[:title].to_s,
          author: item[:author].to_s,
          body: readable_body(item[:body]),
          bodyFull: readable_full_body(item[:body]),
          state: item[:state].to_s,
          updatedAt: item[:updatedAt],
          updatedText: Core::Format.relative_time(item[:updatedAt], now),
          url: item[:url],
          labels: Array(item[:labels]).first(6),
          draft: !!item[:draft],
          comments: item[:comments].to_i,
          reviewComments: item[:reviewComments].to_i
        }
      end

      def readable_body(body)
        text = body.to_s.gsub(/\s+/, " ").strip
        return "No description." if text.empty?

        text.length > 220 ? "#{text[0, 217]}..." : text
      end

      def readable_full_body(body)
        text = body.to_s.gsub(/\r\n?/, "\n").strip
        return "" if text.empty?

        text.length > 8000 ? "#{text[0, 7997]}..." : text
      end

      def empty_heatmap_cells
        start = Date.today - 41
        (0...42).map { |offset| { date: (start + offset).iso8601, count: 0 } }
      end

      def empty_heatmap_cell
        { date: nil, count: 0, intensity: 0, empty: true }
      end

      def repo_status(repo)
        return "error" if repo[:error].to_s != ""
        return "pending" if repo[:pending]
        return "ci-failing" if repo[:ciStatus] == "failing"
        return "dirty" if repo.dig(:local, :dirty)
        return "work" if repo.dig(:stats, :openPulls).to_i.positive? || repo.dig(:stats, :openIssues).to_i.positive?

        "quiet"
      end
    end
  end
end
