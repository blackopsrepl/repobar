# frozen_string_literal: true

require "date"

module RepoBar
  module Runtime
    module Presenter
      module_function

      # Triage scoring. Signals are the shared vocabulary between the inbox rows,
      # the reader pane, and the Ruby tests: each one carries a human label, a
      # tone for the chip, an action hint, and an additive weight. The clamped sum
      # is the attention score that decides what the inbox pulls to the top.
      TRIAGE_STALE_DAYS = 14
      TRIAGE_HOT_COMMENTS = 5
      TRIAGE_FLAGGED_SCORE = 3
      TRIAGE_MAX_ATTENTION = 99

      TRIAGE_LABEL_RULES = [
        {
          id: "priority", label: "priority", tone: "bad", weight: 3,
          hint: "Label says priority — handle next",
          pattern: /(?:\A|[^a-z0-9])(?:p0|p1|blocker|urgent|critical|prio\w*|priority\w*)(?:\z|[^a-z0-9])/
        },
        {
          id: "blocked", label: "blocked", tone: "warn", weight: 3,
          hint: "Marked blocked or waiting — unblock or close",
          pattern: /\bblocked\b|\bon hold\b|\bwaiting\b|\bstalled\b|\bpaused\b/
        },
        {
          id: "bug", label: "bug", tone: "bad", weight: 2,
          hint: "Reported as a bug — reproduce or label",
          pattern: /\bbug\b|\bregression\b|\bbroken\b|\bdefect\b/
        },
        {
          id: "review", label: "needs review", tone: "warn", weight: 2,
          hint: "Label asks for review — review it",
          pattern: /\bneeds?[ _-]?review\b|\breview[ _-]?needed\b|\bawaiting[ _-]?review\b|\bneeds?[ _-]?changes\b/
        },
        {
          id: "help", label: "help wanted", tone: "info", weight: 0,
          hint: "Contributor-friendly — good candidate to share",
          pattern: /\bgood[ _-]?first[ _-]?issue\b|\bhelp[ _-]?wanted\b/
        }
      ].freeze

      TRIAGE_BUCKET_LABELS = {
        "flagged" => "Needs attention",
        "today" => "Today",
        "week" => "This week",
        "month" => "This month",
        "older" => "Older"
      }.freeze

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
          triage: triage_view(repo_views, now)
        }
      end

      # Cross-repository work queue for the triage mode. One flat, newest-first
      # inbox built entirely from the cached snapshot so the UI never blocks on
      # the network, plus the per-item signal set the reader and the rows share.
      def triage_view(repo_views, now = Time.now)
        items = repo_views.flat_map do |repo|
          Array(repo[:pulls]).map { |item| triage_item(repo, item, "pr", now) } +
            Array(repo[:issues]).map { |item| triage_item(repo, item, "issue", now) }
        end
        items.sort_by! { |item| item[:updatedAt].to_s }
        items.reverse!
        flagged = items.select { |item| item[:flagged] }
        oldest = items.max_by { |item| [item[:ageDays].to_i, item[:updatedAt].to_s] }
        next_up = flagged.max_by { |item| [item[:attention].to_i, item[:updatedAt].to_s] }
        {
          total: items.length,
          pullCount: count_kind(items, "pr"),
          issueCount: count_kind(items, "issue"),
          draftCount: items.count { |item| item[:draft] },
          flaggedCount: flagged.length,
          staleCount: items.count { |item| item[:stale] },
          unansweredCount: items.count { |item| signal?(item, "unanswered") },
          repoCount: repo_views.count { |repo| repo_work_count(repo).positive? },
          newCount: items.count { |item| signal?(item, "fresh") },
          ageSpanText: items.empty? ? "" : "#{oldest[:ageText]} oldest · #{items.first[:updatedText]} newest",
          nextUpId: next_up && next_up[:id],
          repos: triage_repos(repo_views, items),
          items: items
        }
      end

      def triage_item(repo, item, kind, now)
        updated_at = item[:updatedAt]
        age_days = triage_age_days(updated_at, now)
        signals = triage_signals(repo, item, kind, age_days)
        attention = signals.sum { |signal| signal[:weight].to_i }.clamp(0, TRIAGE_MAX_ATTENTION)
        bucket = triage_bucket(attention, age_days)
        {
          id: "#{repo[:fullName].to_s.downcase}##{item[:number]}",
          kind: kind,
          repoFullName: repo[:fullName],
          owner: repo[:owner],
          ownerAvatarUrl: repo[:ownerAvatarUrl],
          number: item[:number],
          title: item[:title],
          author: item[:author],
          authorAvatarUrl: item[:authorAvatarUrl],
          authorUrl: item[:authorUrl],
          draft: !!item[:draft],
          updatedAt: updated_at,
          updatedText: item[:updatedText],
          ageDays: age_days,
          ageText: triage_age_text(age_days),
          url: item[:url],
          labels: item[:labels],
          labelChips: triage_label_chips(item[:labels]),
          comments: item[:comments].to_i,
          reviewComments: item[:reviewComments].to_i,
          activity: item[:comments].to_i + item[:reviewComments].to_i,
          answered: kind == "pr" ? true : item[:comments].to_i.positive?,
          stale: age_days >= TRIAGE_STALE_DAYS,
          attention: attention,
          flagged: attention >= TRIAGE_FLAGGED_SCORE,
          bucket: bucket,
          bucketLabel: TRIAGE_BUCKET_LABELS[bucket],
          action: triage_action(item, signals, age_days),
          summary: triage_summary(item),
          signals: signals.map { |signal| signal.reject { |key, _| key == :weight } },
          repo: triage_repo_context(repo),
          body: item[:body],
          bodyFull: item[:bodyFull]
        }
      end

      def triage_signals(repo, item, kind, age_days)
        signals = []
        signals << triage_signal("ci", "CI failing", "bad", 3, "CI is red on this repo — fix or triage") if repo[:ciStatus] == "failing"
        signals << triage_signal("dirty", "local dirty", "warn", 1, "Local checkout is dirty — commit, stash, or discard") if repo.dig(:local, :dirty)
        triage_label_rules(item[:labels]).each do |rule|
          signals << triage_signal(rule[:id], rule[:label], rule[:tone], rule[:weight], rule[:hint])
        end
        if kind == "pr"
          if item[:reviewComments].to_i.positive?
            signals << triage_signal("reviewing", "#{item[:reviewComments]} review comments", "info", 1, "Review thread is live — read the comments")
          elsif !item[:draft]
            signals << triage_signal("unreviewed", "no review yet", "warn", 2, "No review has started — review or request one")
          end
        elsif item[:comments].to_i.zero?
          signals << triage_signal("unanswered", "unanswered", "warn", 2, "No replies yet — answer or close")
        end
        if item[:comments].to_i >= TRIAGE_HOT_COMMENTS
          signals << triage_signal("hot", "#{item[:comments]} comments", "info", 1, "Active thread — join the discussion")
        end
        signals << triage_signal("draft", "draft", "muted", -2, "Draft — not ready for review") if item[:draft]
        if age_days >= TRIAGE_STALE_DAYS
          signals << triage_signal("stale", "quiet #{triage_age_text(age_days)}", "muted", 1, "Quiet for #{triage_age_text(age_days)} — close or revive")
        else
          signals << triage_signal("fresh", "new", "info", 1, "Opened #{triage_age_text(age_days)} — triage it")
        end
        signals
      end

      def triage_signal(id, label, tone, weight, hint)
        { id: id, label: label, tone: tone, weight: weight, hint: hint }
      end

      def triage_label_rules(labels)
        downcased = Array(labels).map { |label| label.to_s.downcase }
        TRIAGE_LABEL_RULES.select { |rule| downcased.any? { |label| rule[:pattern].match?(label) } }
      end

      def triage_label_chips(labels)
        Array(labels).first(8).map do |label|
          name = label.to_s
          rule = TRIAGE_LABEL_RULES.find { |candidate| candidate[:pattern].match?(name.downcase) }
          { name: name, tone: rule ? rule[:tone] : "muted" }
        end
      end

      def triage_action(item, signals, age_days)
        # "fresh" is informational, not a blocker: a draft or a quiet item should
        # not be told to "triage it now" just because it is recent.
        blockers = signals.select { |signal| signal[:weight].to_i.positive? && signal[:id] != "fresh" }
        top = blockers.max_by { |signal| signal[:weight].to_i }
        return top[:hint] if top
        return "Draft — not ready for review" if item[:draft]
        return "Quiet for #{triage_age_text(age_days)} — close or revive" if age_days >= TRIAGE_STALE_DAYS

        "Open #{triage_age_text(age_days)} — nothing flagged yet"
      end

      def triage_summary(item)
        parts = []
        parts << "#{item[:comments].to_i} comment#{item[:comments].to_i == 1 ? '' : 's'}" if item[:comments].to_i.positive?
        parts << "#{item[:reviewComments].to_i} review comment#{item[:reviewComments].to_i == 1 ? '' : 's'}" if item[:reviewComments].to_i.positive?
        parts << "#{Array(item[:labels]).length} labels" if Array(item[:labels]).any?
        parts.join(" · ")
      end

      def triage_bucket(attention, age_days)
        return "flagged" if attention >= TRIAGE_FLAGGED_SCORE
        return "today" if age_days < 2
        return "week" if age_days < 7
        return "month" if age_days < 30

        "older"
      end

      def triage_age_days(updated_at, now)
        time = Core::Format.parse_time(updated_at)
        return 0 unless time

        [((now - time) / 86_400.0).floor, 0].max
      end

      def triage_age_text(age_days)
        return "today" if age_days.to_i < 1

        "#{age_days.to_i}d"
      end

      def triage_repo_context(repo)
        {
          fullName: repo[:fullName],
          name: repo[:name],
          owner: repo[:owner],
          ownerAvatarUrl: repo[:ownerAvatarUrl],
          url: repo[:url],
          description: repo[:description],
          private: repo[:private],
          ciStatus: repo[:ciStatus],
          status: repo[:status],
          stars: repo[:stars],
          forks: repo[:forks],
          openPulls: repo[:openPulls],
          openIssues: repo[:openIssues],
          pushedText: repo[:pushedText],
          releaseTag: repo[:latestRelease] && repo[:latestRelease][:tag],
          releaseUrl: repo[:latestRelease] && repo[:latestRelease][:url],
          heatmapText: "#{repo.dig(:heatmap, :total).to_i} commits / 6m",
          local: repo[:local],
          pending: repo[:pending],
          error: repo[:error]
        }
      end

      def triage_repos(repo_views, items)
        repo_views.filter_map do |repo|
          repo_items = items.select { |item| item[:repoFullName] == repo[:fullName] }
          next if repo_items.empty?

          {
            fullName: repo[:fullName],
            owner: repo[:owner],
            ownerAvatarUrl: repo[:ownerAvatarUrl],
            url: repo[:url],
            total: repo_items.length,
            pullCount: count_kind(repo_items, "pr"),
            issueCount: count_kind(repo_items, "issue"),
            flaggedCount: repo_items.count { |item| item[:flagged] },
            staleCount: repo_items.count { |item| item[:stale] },
            attention: repo_items.sum { |item| item[:attention].to_i },
            oldestText: repo_items.max_by { |item| item[:ageDays].to_i }&.dig(:ageText),
            oldestAgeDays: repo_items.map { |item| item[:ageDays].to_i }.max.to_i,
            ciStatus: repo[:ciStatus],
            status: repo[:status],
            stars: repo[:stars],
            openPulls: repo[:openPulls],
            openIssues: repo[:openIssues],
            pushedText: repo[:pushedText],
            local: repo[:local],
            pending: repo[:pending]
          }
        end.sort_by { |entry| [-entry[:flaggedCount], -entry[:attention].to_i, entry[:fullName].to_s.downcase] }
      end

      def count_kind(items, kind)
        items.count { |item| item[:kind] == kind }
      end

      def signal?(item, id)
        Array(item[:signals]).any? { |signal| signal[:id] == id }
      end

      def repo_work_count(repo)
        Array(repo[:pulls]).length + Array(repo[:issues]).length
      end

      # A thread is fetched on demand and lives in thread.json, so the presenter
      # only shapes whatever the caller hands it: entries plus a reading summary.
      def thread_view(thread_state, now = Time.now)
        return nil unless thread_state

        entries = Array(thread_state[:entries]).map { |entry| thread_entry_view(entry, now) }
        participants = entries.map { |entry| entry[:author] }.reject { |name| name.to_s.empty? }.uniq
        {
          status: thread_state[:status].to_s,
          itemId: thread_state[:itemId].to_s,
          repoFullName: thread_state[:repoFullName].to_s,
          number: thread_state[:number].to_s,
          kind: thread_state[:kind].to_s,
          title: thread_state[:title].to_s,
          url: thread_state[:url].to_s,
          error: thread_state[:error].to_s,
          updatedText: Core::Format.relative_time(thread_state[:updatedAt], now),
          total: entries.length,
          commentCount: entries.count { |entry| entry[:kind] == "comment" },
          reviewCount: entries.count { |entry| entry[:kind] == "review" },
          reviewCommentCount: entries.count { |entry| entry[:kind] == "review-comment" },
          participantCount: participants.length,
          participants: participants.first(8),
          truncated: !!thread_state[:truncated],
          entries: entries
        }
      end

      def thread_entry_view(entry, now)
        body = entry[:body].to_s.gsub(/\r\n?/, "\n").strip
        {
          id: entry[:id].to_i,
          kind: entry[:kind].to_s,
          author: entry[:author].to_s,
          authorAvatarUrl: entry[:authorAvatarUrl],
          authorUrl: entry[:authorUrl],
          body: body,
          bodyPreview: readable_body(entry[:body]),
          bodyLength: body.length,
          createdAt: entry[:createdAt],
          createdText: Core::Format.relative_time(entry[:createdAt], now),
          url: entry[:url],
          state: entry[:state].to_s,
          path: entry[:path],
          line: entry[:line],
          side: entry[:side].to_s,
          inReplyToId: entry[:inReplyToId].to_i
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
        {
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
        text = work.empty? ? "#{summary[:repoCount]} repos" : work.first(2).join(" ")

        tooltip = [
          "RepoBar (GitHub)",
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
          authorAvatarUrl: item[:authorAvatarUrl],
          authorUrl: item[:authorUrl],
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
