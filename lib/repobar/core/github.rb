# frozen_string_literal: true

require "json"
require "net/http"
require "date"
require "time"
require "uri"

module RepoBar
  module Core
    module GitHub
      module_function

      Response = Struct.new(:data, :headers, :status, keyword_init: true)

      def auth_status(config)
        token = access_token(config)
        if token.to_s.empty? && forgejo?(config)
          response = request(config, "/version", token: nil)
          return {
            authenticated: true,
            source: "public",
            login: "forgejo:public",
            provider: "forgejo",
            version: response.data[:version] || response.data["version"],
            rateLimit: rate_limit_from_headers(response.headers)
          }
        end
        return { authenticated: false, source: config.dig(:github, :authSource), login: nil, error: "No GitHub token available." } if token.to_s.empty?

        response = request(config, "/user", token: token)
        login = response.data[:login] || response.data["login"]
        {
          authenticated: true,
          source: config.dig(:github, :authSource),
          login: login,
          provider: provider(config),
          rateLimit: rate_limit_from_headers(response.headers)
        }
      rescue StandardError => e
        { authenticated: false, source: config.dig(:github, :authSource), login: nil, error: e.message }
      end

      def fetch_repositories(config)
        token = access_token(config)
        raise "No GitHub token available. Run gh auth login or set REPOBAR_GITHUB_TOKEN." if token.to_s.empty? && github?(config)

        limit = config.dig(:repoList, :displayLimit).to_i
        pinned = Array(config.dig(:repoList, :pinnedRepositories))
        visible = Array(config.dig(:repoList, :visibleRepositories))
        hidden = Array(config.dig(:repoList, :hiddenRepositories))
        candidates = (pinned + visible).uniq

        base_repos = if candidates.empty?
                       user_repositories(config, token, [limit * 2, 20].max)
                     else
                       candidates.filter_map { |full_name| repository(config, token, full_name) }
                     end

        filtered = base_repos
          .reject { |repo| hidden.include?(repo[:fullName].downcase) }
          .reject { |repo| repo[:fork] && !config.dig(:repoList, :showForks) }
          .reject { |repo| repo[:archived] && !config.dig(:repoList, :showArchived) }
        sorted = sort_repositories(filtered, config.dig(:repoList, :menuSort))
        pinned_repos = pinned.filter_map { |name| sorted.find { |repo| repo[:fullName].casecmp?(name) } }
        unpinned_repos = sorted.reject { |repo| pinned.include?(repo[:fullName].downcase) }
        selected = (pinned_repos + unpinned_repos.first(limit)).uniq { |repo| repo[:fullName].downcase }
        selected.map { |repo| hydrate_repository(config, token, repo) }
      end

      def user_repositories(config, token, limit)
        path = if forgejo?(config)
                 "/repos/search?limit=#{[[limit, 50].min, 1].max}"
               else
                 "/user/repos?per_page=#{[[limit, 100].min, 1].max}&sort=pushed&direction=desc"
               end
        response = request(config, path, token: token)
        items = forgejo?(config) ? response.data[:data] || response.data["data"] : response.data
        Array(items).map { |item| map_repo_item(item, response.headers, config) }
      end

      def search_repositories(config, token, query, limit)
        encoded = URI.encode_www_form_component(query.to_s)
        path = if forgejo?(config)
                 "/repos/search?q=#{encoded}&limit=#{limit}"
               else
                 "/search/repositories?q=#{encoded}&per_page=#{limit}"
               end
        response = request(config, path, token: token)
        items = forgejo?(config) ? response.data[:data] || response.data["data"] : response.data[:items] || response.data["items"]
        Array(items).first(limit).map { |item| map_repo_item(item, response.headers, config) }
      rescue StandardError
        []
      end

      def repository(config, token, full_name)
        response = request(config, "/repos/#{full_name}", token: token)
        map_repo_item(response.data, response.headers, config)
      rescue StandardError => e
        # A missing repository is a confirmed removal. Other failures must reach the
        # refresh transaction so it retains the last confirmed repository snapshot.
        raise unless e.message.match?(/\bHTTP 404:/)

        nil
      end

      def hydrate_repository(config, token, repo)
        owner = repo[:owner]
        name = repo[:name]
        issue_count = open_issue_count(config, token, "#{owner}/#{name}", repo)
        pull_count = open_pull_count(config, token, "#{owner}/#{name}", repo)
        issue_items = issue_count.positive? ? issues(config, token, owner, name, 20) : []
        pull_items = pull_count.positive? ? pulls(config, token, owner, name, 20) : []
        release = latest_release(config, token, owner, name)
        ci = latest_ci(config, token, owner, name)
        activity = recent_activity(config, token, owner, name)
        traffic = traffic(config, token, owner, name)
        heatmap = heatmap(config, token, owner, name)
        repo.merge(
          stats: repo.fetch(:stats, {}).merge(openIssues: issue_count, openPulls: pull_count),
          latestRelease: release,
          ciStatus: ci[:status],
          ciRun: ci[:run],
          latestActivity: activity.first,
          activity: activity,
          issues: issue_items,
          pulls: pull_items,
          traffic: traffic,
          heatmap: heatmap
        )
      rescue StandardError => e
        repo.merge(error: e.message)
      end

      def search_count(config, token, query)
        response = request(config, "/search/issues?q=#{URI.encode_www_form_component(query)}&per_page=1", token: token)
        (response.data[:total_count] || response.data["total_count"]).to_i
      rescue StandardError
        0
      end

      def open_issue_count(config, token, full_name, repo = nil)
        return repo.dig(:stats, :openIssues).to_i if forgejo?(config) && repo
        return repository(config, token, full_name).dig(:stats, :openIssues).to_i if forgejo?(config)

        search_count(config, token, "repo:#{full_name} type:issue state:open")
      end

      def open_pull_count(config, token, full_name, repo = nil)
        return repo.dig(:stats, :openPulls).to_i if forgejo?(config) && repo
        return repository(config, token, full_name).dig(:stats, :openPulls).to_i if forgejo?(config)

        search_count(config, token, "repo:#{full_name} type:pr state:open")
      end

      def issues(config, token, owner, name, limit)
        response = request(config, "/repos/#{owner}/#{name}/issues?state=open&#{limit_param(config)}=#{limit}", token: token)
        Array(response.data).reject { |item| item[:pull_request] || item["pull_request"] }.first(limit).map { |item| map_issue_item(item) }
      rescue StandardError
        []
      end

      def pulls(config, token, owner, name, limit)
        response = request(config, "/repos/#{owner}/#{name}/pulls?state=open&#{limit_param(config)}=#{limit}", token: token)
        Array(response.data).first(limit).map { |item| map_pull_item(item) }
      rescue StandardError
        []
      end

      def releases(config, token, owner, name, limit)
        response = request(config, "/repos/#{owner}/#{name}/releases?#{limit_param(config)}=#{limit}", token: token)
        Array(response.data).first(limit).map { |item| map_release_item(item) }
      rescue StandardError
        []
      end

      def workflow_runs(config, token, owner, name, limit)
        response = request(config, "/repos/#{owner}/#{name}/actions/runs?#{limit_param(config)}=#{limit}", token: token)
        Array(response.data[:workflow_runs] || response.data["workflow_runs"]).first(limit).map { |item| map_workflow_run(item) }
      rescue StandardError
        []
      end

      def tags(config, token, owner, name, limit)
        response = request(config, "/repos/#{owner}/#{name}/tags?#{limit_param(config)}=#{limit}", token: token)
        Array(response.data).first(limit).map do |item|
          {
            name: item[:name] || item["name"],
            sha: item.dig(:commit, :sha) || item.dig("commit", "sha"),
            url: item[:zipball_url] || item["zipball_url"] || item[:tarball_url] || item["tarball_url"]
          }
        end
      rescue StandardError
        []
      end

      def branches(config, token, owner, name, limit)
        response = request(config, "/repos/#{owner}/#{name}/branches?#{limit_param(config)}=#{limit}", token: token)
        Array(response.data).first(limit).map do |item|
          {
            name: item[:name] || item["name"],
            sha: item.dig(:commit, :sha) || item.dig("commit", "sha"),
            protected: !!(item[:protected] || item["protected"]),
            url: "#{config.dig(:github, :host).to_s.sub(%r{/*\z}, '')}/#{owner}/#{name}/src/branch/#{URI.encode_www_form_component(item[:name] || item["name"])}"
          }
        end
      rescue StandardError
        []
      end

      def contributors(config, token, owner, name, limit)
        response = request(config, "/repos/#{owner}/#{name}/contributors?#{limit_param(config)}=#{limit}", token: token)
        Array(response.data).first(limit).map do |item|
          {
            login: item[:login] || item["login"],
            contributions: (item[:contributions] || item["contributions"]).to_i,
            url: item[:html_url] || item["html_url"]
          }
        end
      rescue StandardError
        []
      end

      def discussions(config, token, owner, name, limit)
        return [] if forgejo?(config) || token.to_s.empty?

        query = <<~GRAPHQL
          query($owner: String!, $name: String!, $limit: Int!) {
            repository(owner: $owner, name: $name) {
              discussions(first: $limit, orderBy: {field: UPDATED_AT, direction: DESC}) {
                nodes {
                  number
                  title
                  url
                  updatedAt
                  author { login }
                  comments { totalCount }
                }
              }
            }
          }
        GRAPHQL
        data = graphql_request(config, token, query, { owner: owner, name: name, limit: limit })
        Array(data.dig(:data, :repository, :discussions, :nodes)).map do |item|
          {
            number: item[:number],
            title: item[:title],
            author: item.dig(:author, :login),
            comments: item.dig(:comments, :totalCount).to_i,
            updatedAt: item[:updatedAt],
            url: item[:url]
          }
        end
      rescue StandardError
        []
      end

      def commits(config, token, owner, name, limit)
        response = request(config, "/repos/#{owner}/#{name}/commits?#{limit_param(config)}=#{limit}", token: token)
        Array(response.data).first(limit).map do |item|
          commit = item[:commit] || item["commit"] || {}
          author = commit[:author] || commit["author"] || {}
          {
            sha: item[:sha] || item["sha"],
            message: commit[:message] || commit["message"],
            author: item.dig(:author, :login) || item.dig("author", "login") || author[:name] || author["name"],
            date: author[:date] || author["date"],
            url: item[:html_url] || item["html_url"]
          }
        end
      rescue StandardError
        []
      end

      def global_activity(config, token, login, limit)
        return [] if login.to_s.empty?

        path = forgejo?(config) ? "/users/#{login}/activities/feeds?limit=#{limit}" : "/users/#{login}/events/public?per_page=#{limit}"
        response = request(config, path, token: token)
        Array(response.data).first(limit).map do |event|
          if forgejo?(config)
            repo = event.dig(:repo, :full_name) || event.dig("repo", "full_name")
            {
              type: event[:op_type] || event["op_type"],
              actor: event.dig(:act_user, :login) || event.dig("act_user", "login") || login,
              repo: repo,
              title: forgejo_activity_title(event),
              date: event[:created] || event["created"],
              url: repo ? "#{config.dig(:github, :host).to_s.sub(%r{/*\z}, '')}/#{repo}" : config.dig(:github, :host)
            }
          else
            repo = event.dig(:repo, :name) || event.dig("repo", "name")
            {
              type: event[:type] || event["type"],
              actor: event.dig(:actor, :login) || event.dig("actor", "login") || login,
              repo: repo,
              title: activity_title(event),
              date: event[:created_at] || event["created_at"],
              url: repo ? "https://github.com/#{repo}" : "https://github.com/#{login}"
            }
          end
        end
      rescue StandardError
        []
      end

      def account_heatmap(config, token, login)
        return forgejo_account_heatmap(config, token, login) if forgejo?(config)
        return unavailable_heatmap if token.to_s.empty? || login.to_s.empty?

        start_date = Date.today - 365
        query = <<~GRAPHQL
          query($login: String!, $from: DateTime!, $to: DateTime!) {
            user(login: $login) {
              contributionsCollection(from: $from, to: $to) {
                contributionCalendar {
                  totalContributions
                  weeks {
                    contributionDays {
                      date
                      contributionCount
                    }
                  }
                }
              }
            }
          }
        GRAPHQL
        data = graphql_request(
          config,
          token,
          query,
          {
            login: login,
            from: Time.utc(start_date.year, start_date.month, start_date.day).iso8601,
            to: Time.now.utc.iso8601
          }
        )
        calendar = data.dig(:data, :user, :contributionsCollection, :contributionCalendar) || {}
        weeks = Array(calendar[:weeks]).map do |week|
          {
            cells: Array(week[:contributionDays]).map do |day|
              { date: day[:date], count: day[:contributionCount].to_i }
            end
          }
        end
        cells = weeks.flat_map { |week| week[:cells] }
        max = cells.map { |cell| cell[:count].to_i }.max.to_i
        total = (calendar[:totalContributions] || cells.sum { |cell| cell[:count].to_i }).to_i
        { available: true, total: total, max: max, cells: cells, weeks: weeks }
      rescue StandardError
        unavailable_heatmap
      end

      def forgejo_account_heatmap(config, token, login)
        heatmap_login = forgejo_heatmap_login(login)
        return unavailable_heatmap if heatmap_login.empty?

        start_date = Date.today - 365
        end_date = Date.today
        response = request(config, "/users/#{URI.encode_www_form_component(heatmap_login)}/heatmap", token: token)
        counts = Hash.new(0)
        Array(response.data).each do |item|
          date = forgejo_heatmap_date(item)
          next unless date && date >= start_date && date <= end_date

          counts[date.iso8601] += (item[:contributions] || item["contributions"] || item[:count] || item["count"]).to_i
        end
        weeks = calendar_weeks_from_counts(counts, start_date, end_date)
        cells = weeks.flat_map { |week| week[:cells] }
        max = cells.map { |cell| cell[:count].to_i }.max.to_i
        { available: true, total: cells.sum { |cell| cell[:count].to_i }, max: max, cells: cells, weeks: weeks, login: heatmap_login }
      rescue StandardError
        unavailable_heatmap
      end

      def forgejo_heatmap_login(login)
        clean = login.to_s.strip
        return clean unless clean.empty? || clean == "forgejo:public"

        configured = ENV["REPOBAR_FORGEJO_LOGIN"].to_s.strip
        return configured unless configured.empty?

        ENV["USER"].to_s.strip
      end

      def forgejo_heatmap_date(item)
        timestamp = (item[:timestamp] || item["timestamp"]).to_i
        return nil if timestamp <= 0

        timestamp /= 1000 if timestamp > 20_000_000_000
        Time.at(timestamp).utc.to_date
      rescue StandardError
        nil
      end

      def calendar_weeks_from_counts(counts, start_date, end_date)
        week_start = start_date - start_date.wday
        last_week_start = end_date - end_date.wday
        weeks = []
        while week_start <= last_week_start
          weeks << {
            cells: (0...7).map do |day|
              date = week_start + day
              { date: date.iso8601, count: date >= start_date && date <= end_date ? counts[date.iso8601].to_i : 0 }
            end
          }
          week_start += 7
        end
        weeks
      end

      def traffic(config, token, owner, name)
        return nil if forgejo?(config) || token.to_s.empty?

        views = request(config, "/repos/#{owner}/#{name}/traffic/views", token: token).data
        clones = request(config, "/repos/#{owner}/#{name}/traffic/clones", token: token).data
        {
          views: (views[:count] || views["count"]).to_i,
          uniqueViews: (views[:uniques] || views["uniques"]).to_i,
          clones: (clones[:count] || clones["count"]).to_i,
          uniqueClones: (clones[:uniques] || clones["uniques"]).to_i
        }
      rescue StandardError
        nil
      end

      def heatmap(config, token, owner, name)
        cells = activity_heatmap(config, token, owner, name)
        total = cells.sum { |cell| cell[:count].to_i }
        max = cells.map { |cell| cell[:count].to_i }.max.to_i
        { total: total, max: max, cells: cells }
      rescue StandardError
        { total: 0, max: 0, cells: [] }
      end

      def activity_heatmap(config, token, owner, name)
        counts = Hash.new(0)
        commits(config, token, owner, name, 100).each do |commit|
          date = Core::Format.parse_time(commit[:date])&.utc&.to_date&.iso8601
          counts[date] += 1 if date
        end
        start = Date.today - 181
        (0...182).map do |offset|
          date = (start + offset).iso8601
          { date: date, count: counts[date].to_i }
        end
      end

      def latest_release(config, token, owner, name)
        response = if forgejo?(config)
                     request(config, "/repos/#{owner}/#{name}/releases?limit=1", token: token)
                   else
                     request(config, "/repos/#{owner}/#{name}/releases/latest", token: token)
                   end
        data = forgejo?(config) ? Array(response.data).first : response.data
        return nil unless data

        {
          name: data[:name].to_s.empty? ? data[:tag_name] || data["tag_name"] : data[:name],
          tag: data[:tag_name] || data["tag_name"],
          publishedAt: data[:published_at] || data["published_at"] || data[:created_at] || data["created_at"],
          url: data[:html_url] || data["html_url"]
        }
      rescue StandardError
        nil
      end

      def map_issue_item(item)
        {
          number: item[:number] || item["number"],
          title: item[:title] || item["title"],
          author: item.dig(:user, :login) || item.dig("user", "login"),
          state: item[:state] || item["state"],
          updatedAt: item[:updated_at] || item["updated_at"],
          url: item[:html_url] || item["html_url"],
          body: item[:body] || item["body"],
          comments: (item[:comments] || item["comments"]).to_i,
          labels: Array(item[:labels] || item["labels"]).map { |label| label[:name] || label["name"] }
        }
      end

      def map_pull_item(item)
        {
          number: item[:number] || item["number"],
          title: item[:title] || item["title"],
          author: item.dig(:user, :login) || item.dig("user", "login"),
          state: item[:state] || item["state"],
          draft: !!(item[:draft] || item["draft"]),
          updatedAt: item[:updated_at] || item["updated_at"],
          url: item[:html_url] || item["html_url"],
          body: item[:body] || item["body"],
          comments: (item[:comments] || item["comments"]).to_i,
          reviewComments: (item[:review_comments] || item["review_comments"]).to_i,
          labels: Array(item[:labels] || item["labels"]).map { |label| label[:name] || label["name"] }
        }
      end

      def map_release_item(item)
        {
          name: item[:name].to_s.empty? ? item[:tag_name] || item["tag_name"] : item[:name],
          tag: item[:tag_name] || item["tag_name"],
          draft: !!(item[:draft] || item["draft"]),
          prerelease: !!(item[:prerelease] || item["prerelease"]),
          publishedAt: item[:published_at] || item["published_at"] || item[:created_at] || item["created_at"],
          url: item[:html_url] || item["html_url"]
        }
      end

      def map_workflow_run(item)
        status = case item[:conclusion] || item["conclusion"]
                 when "success" then "passing"
                 when "failure", "timed_out", "cancelled", "action_required" then "failing"
                 when nil then "pending"
                 else "unknown"
                 end
        {
          id: item[:id] || item["id"],
          name: item[:name] || item["name"],
          status: status,
          rawStatus: item[:status] || item["status"],
          conclusion: item[:conclusion] || item["conclusion"],
          updatedAt: item[:updated_at] || item["updated_at"],
          url: item[:html_url] || item["html_url"]
        }
      end

      def latest_ci(config, token, owner, name)
        limit_key = forgejo?(config) ? "limit" : "per_page"
        response = request(config, "/repos/#{owner}/#{name}/actions/runs?#{limit_key}=1", token: token)
        run = Array(response.data[:workflow_runs] || response.data["workflow_runs"]).first
        return { status: "unknown", run: nil } unless run

        status = case run[:conclusion] || run["conclusion"]
                 when "success" then "passing"
                 when "failure", "timed_out", "cancelled", "action_required" then "failing"
                 when nil then "pending"
                 else "unknown"
                 end
        {
          status: status,
          run: {
            name: run[:name] || run["name"],
            status: run[:status] || run["status"],
            conclusion: run[:conclusion] || run["conclusion"],
            url: run[:html_url] || run["html_url"],
            updatedAt: run[:updated_at] || run["updated_at"]
          }
        }
      rescue StandardError
        { status: "unknown", run: nil }
      end

      def recent_activity(config, token, owner, name, limit = 5)
        response = if forgejo?(config)
                     request(config, "/repos/#{owner}/#{name}/activities/feeds?limit=#{limit}", token: token)
                   else
                     request(config, "/repos/#{owner}/#{name}/events?per_page=#{limit}", token: token)
                   end
        Array(response.data).first(limit).filter_map do |event|
          if forgejo?(config)
            actor = event.dig(:act_user, :login) || event.dig("act_user", "login") || "unknown"
            repo = event.dig(:repo, :full_name) || event.dig("repo", "full_name") || "#{owner}/#{name}"
            next {
              type: event[:op_type] || event["op_type"],
              actor: actor,
              title: forgejo_activity_title(event),
              date: event[:created] || event["created"],
              url: "#{config.dig(:github, :host).to_s.sub(%r{/*\z}, '')}/#{repo}"
            }
          end

          type = event[:type] || event["type"]
          actor = event.dig(:actor, :login) || event.dig("actor", "login") || "unknown"
          created_at = event[:created_at] || event["created_at"]
          {
            type: type,
            actor: actor,
            title: activity_title(event),
            date: created_at,
            url: "https://github.com/#{owner}/#{name}"
          }
        end
      rescue StandardError
        []
      end

      def forgejo_activity_title(event)
        type = event[:op_type] || event["op_type"]
        case type
        when "commit_repo"
          content = event[:content] || event["content"]
          commit_count = content.to_s.empty? ? nil : Array(JSON.parse(content)["Commits"]).length
          commit_count ? "pushed #{commit_count} commit#{commit_count == 1 ? '' : 's'}" : "pushed commits"
        when "create_repo"
          "created repository"
        when "rename_repo"
          "renamed repository"
        when "create_issue"
          "opened issue"
        when "create_pull_request"
          "opened pull request"
        else
          type.to_s.tr("_", " ")
        end
      rescue StandardError
        type.to_s.tr("_", " ")
      end

      def activity_title(event)
        type = event[:type] || event["type"]
        repo_name = event.dig(:repo, :name) || event.dig("repo", "name")
        case type
        when "PushEvent"
          count = Array(event.dig(:payload, :commits) || event.dig("payload", "commits")).length
          "pushed #{count} commit#{count == 1 ? '' : 's'}"
        when "IssuesEvent"
          action = event.dig(:payload, :action) || event.dig("payload", "action")
          issue = event.dig(:payload, :issue, :number) || event.dig("payload", "issue", "number")
          "#{action} issue ##{issue}"
        when "PullRequestEvent"
          action = event.dig(:payload, :action) || event.dig("payload", "action")
          pr = event.dig(:payload, :pull_request, :number) || event.dig("payload", "pull_request", "number")
          "#{action} PR ##{pr}"
        else
          type.to_s.sub(/Event\z/, "").downcase
        end
      rescue StandardError
        "activity in #{repo_name}"
      end

      def map_repo_item(item, headers = {}, config = nil)
        owner = item.dig(:owner, :login) || item.dig("owner", "login")
        name = item[:name] || item["name"]
        full_name = item[:full_name] || item["full_name"] || "#{owner}/#{name}"
        {
          id: full_name.downcase,
          fullName: full_name,
          owner: owner,
          ownerAvatarUrl: item.dig(:owner, :avatar_url) || item.dig("owner", "avatar_url"),
          ownerUrl: item.dig(:owner, :html_url) || item.dig("owner", "html_url"),
          name: name,
          description: item[:description] || item["description"],
          url: item[:html_url] || item["html_url"],
          private: !!(item[:private] || item["private"]),
          fork: !!(item[:fork] || item["fork"]),
          archived: !!(item[:archived] || item["archived"]),
          updatedAt: item[:updated_at] || item["updated_at"],
          stats: {
            stars: (item[:stargazers_count] || item["stargazers_count"] || item[:stars_count] || item["stars_count"]).to_i,
            forks: (item[:forks_count] || item["forks_count"]).to_i,
            pushedAt: item[:pushed_at] || item["pushed_at"] || item[:updated_at] || item["updated_at"],
            openIssues: (forgejo?(config) ? item[:open_issues_count] || item["open_issues_count"] : 0).to_i,
            openPulls: (forgejo?(config) ? item[:open_pr_counter] || item["open_pr_counter"] : 0).to_i
          },
          ciStatus: "unknown",
          rateLimit: rate_limit_from_headers(headers)
        }
      end

      def sort_repositories(repos, key)
        case key.to_s
        when "issues"
          repos.sort_by { |repo| -repo.dig(:stats, :openIssues).to_i }
        when "prs"
          repos.sort_by { |repo| -repo.dig(:stats, :openPulls).to_i }
        when "stars"
          repos.sort_by { |repo| -repo.dig(:stats, :stars).to_i }
        when "repo"
          repos.sort_by { |repo| repo[:fullName].to_s.downcase }
        else
          repos.sort_by { |repo| Core::Format.parse_time(repo.dig(:stats, :pushedAt) || repo[:updatedAt]) || Time.at(0) }.reverse
        end
      end

      def request(config, path, token:)
        uri = URI.join("#{config.dig(:github, :apiHost).to_s.sub(%r{/*\z}, '')}/", path.sub(%r{\A/+}, ""))
        fresh_cached = Cache.rest_entry(config, uri, ttl_seconds: rest_cache_ttl(config))
        return Response.new(data: JSON.parse(fresh_cached["body"], symbolize_names: true), headers: fresh_cached["headers"], status: fresh_cached["status"].to_i) if fresh_cached

        request = Net::HTTP::Get.new(uri)
        request["Accept"] = forgejo?(config) ? "application/json" : "application/vnd.github+json"
        request["X-GitHub-Api-Version"] = "2022-11-28" if github?(config)
        request["User-Agent"] = "repobar-linux"
        request["Authorization"] = forgejo?(config) ? "token #{token}" : "Bearer #{token}" unless token.to_s.empty?
        cached = Cache.rest_entry(config, uri)
        request["If-None-Match"] = cached["headers"]["etag"] if cached && cached.dig("headers", "etag")
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 20, open_timeout: 10) do |http|
          http.request(request)
        end
        if response.is_a?(Net::HTTPNotModified) && cached
          return Response.new(data: JSON.parse(cached["body"], symbolize_names: true), headers: cached["headers"], status: 304)
        end
        data = response.body.to_s.empty? ? {} : JSON.parse(response.body, symbolize_names: true)
        raise "#{provider(config).capitalize} HTTP #{response.code}: #{error_message(data)}" unless response.is_a?(Net::HTTPSuccess)

        Cache.write_rest_entry(config, uri, status: response.code.to_i, headers: response.each_header.to_h, body: response.body.to_s)
        Response.new(data: data, headers: response.each_header.to_h, status: response.code.to_i)
      end

      def graphql_request(config, token, query, variables)
        cache_key = Cache.key(JSON.generate(query: query, variables: variables))
        cached = Cache.graphql_entry(config, cache_key, ttl_seconds: 900)
        return JSON.parse(cached["body"], symbolize_names: true) if cached

        uri = URI("https://api.github.com/graphql")
        request = Net::HTTP::Post.new(uri)
        request["Accept"] = "application/vnd.github+json"
        request["X-GitHub-Api-Version"] = "2022-11-28"
        request["User-Agent"] = "repobar-linux"
        request["Authorization"] = "Bearer #{token}"
        request.body = JSON.generate(query: query, variables: variables)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 20, open_timeout: 10) { |http| http.request(request) }
        data = response.body.to_s.empty? ? {} : JSON.parse(response.body, symbolize_names: true)
        raise "GitHub GraphQL HTTP #{response.code}: #{error_message(data)}" unless response.is_a?(Net::HTTPSuccess)

        Cache.write_graphql_entry(config, cache_key, body: response.body.to_s)
        data
      end

      def access_token(config)
        if forgejo?(config)
          return ENV["REPOBAR_FORGEJO_TOKEN"] if ENV["REPOBAR_FORGEJO_TOKEN"].to_s.strip != ""
          return ENV["FORGEJO_TOKEN"] if ENV["FORGEJO_TOKEN"].to_s.strip != ""
          return ENV["GITEA_TOKEN"] if ENV["GITEA_TOKEN"].to_s.strip != ""
          return config.dig(:github, :token) if config.dig(:github, :token).to_s.strip != ""

          return nil
        end

        return ENV["REPOBAR_GITHUB_TOKEN"] if ENV["REPOBAR_GITHUB_TOKEN"].to_s.strip != ""
        return ENV["GITHUB_TOKEN"] if ENV["GITHUB_TOKEN"].to_s.strip != ""

        return nil unless config.dig(:github, :authSource).to_s == "gh"

        Core::Process.run_text("gh", ["auth", "token"]).strip
      rescue StandardError
        nil
      end

      def error_message(data)
        data[:message] || data["message"] || "request failed"
      end

      def rate_limit_from_headers(headers)
        reset = headers["x-ratelimit-reset"]
        {
          limit: headers["x-ratelimit-limit"]&.to_i,
          remaining: headers["x-ratelimit-remaining"]&.to_i,
          used: headers["x-ratelimit-used"]&.to_i,
          resource: headers["x-ratelimit-resource"],
          resetAt: reset ? Time.at(reset.to_i).utc.iso8601 : nil
        }
      end

      def provider(config)
        return "github" unless config.respond_to?(:dig)

        config.dig(:github, :provider).to_s == "forgejo" ? "forgejo" : "github"
      end

      def forgejo?(config)
        provider(config) == "forgejo"
      end

      def github?(config)
        provider(config) == "github"
      end

      def limit_param(config)
        forgejo?(config) ? "limit" : "per_page"
      end

      def rest_cache_ttl(config)
        seconds = config.dig(:runtime, :refreshSeconds).to_i
        [[seconds, 30].max, 300].min
      end

      def unavailable_heatmap
        { available: false, total: 0, max: 0, cells: [] }
      end
    end
  end
end
