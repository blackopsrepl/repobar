# frozen_string_literal: true

require_relative "test_helper"

class ThreadGitHubTest < Minitest::Test
  GitHub = RepoBar::Core::GitHub

  def test_issue_thread_fetches_every_linked_page_without_default_cap
    config = build_config
    path = "/repos/one/repo/issues/7/comments?per_page=100"
    next_path = "#{path}&page=2"
    pages = {
      path => response((1..100).map { |id| entry(id) }, next_path),
      next_path => response([entry(101)], nil, previous: path)
    }
    calls = []

    GitHub.stub(:request, lambda { |_config, requested, token:|
      assert_equal "token", token
      calls << requested
      pages.fetch(requested)
    }) do
      thread = GitHub.item_thread(config, "token", "one", "repo", 7, "issue")
      assert_equal (1..101).to_a, thread.map { |item| item[:id] }
      assert_equal [path, next_path], calls
    end
  end

  def test_pr_thread_merges_all_endpoint_pages_chronologically_with_avatars
    config = build_config
    pages = pr_pages
    calls = []
    GitHub.stub(:request, lambda { |_config, path, token:|
      calls << path
      pages.fetch(path)
    }) do
      thread = GitHub.item_thread(config, "token", "one", "repo", 7, "pr")
      assert_equal [1, 2, 3, 4, 5, 6], thread.map { |item| item[:id] }
      assert_equal ["comment", "review", "review-comment", "review", "review-comment", "comment"],
        thread.map { |item| item[:kind] }
      thread.each do |item|
        id = item[:id]
        assert_equal "user#{id}", item[:author]
        assert_equal "https://avatars.githubusercontent.com/u/#{id}", item[:authorAvatarUrl]
        assert_equal "https://github.com/user#{id}", item[:authorUrl]
        assert_equal "Body #{id}", item[:body]
      end
      assert_equal "APPROVED", thread[1][:state]
      assert_equal "lib/code.rb", thread[2][:path]
      assert_equal 42, thread[2][:line]
      assert_equal 3, thread[4][:inReplyToId]
      assert_equal "RIGHT", thread[4][:side]
      assert_equal pages.keys.sort, calls.sort
    end
  end

  def test_endpoint_errors_propagate_instead_of_returning_partial_threads
    config = build_config
    pr_pages.each_key do |failed_path|
      failure = RuntimeError.new("GitHub HTTP 503: #{failed_path}")
      GitHub.stub(:request, lambda { |_config, path, token:|
        raise failure if path == failed_path

        pr_pages.fetch(path)
      }) do
        error = assert_raises(RuntimeError, "failure at #{failed_path}") do
          GitHub.item_thread(config, "token", "one", "repo", 7, "pr")
        end
        assert_same failure, error
      end
    end
  end

  def test_review_line_never_uses_diff_positions_as_line_numbers
    [false, true].each do |string_keys|
      cases = [
        [{ line: 8, original_line: 7, position: 3 }, 8],
        [{ line: nil, original_line: 7, position: 3 }, 7],
        [{ line: nil, original_line: nil, position: 3, original_position: 4 }, nil]
      ]
      cases.each do |fields, expected|
        item = entry(1).merge(fields)
        item = JSON.parse(JSON.generate(item)) if string_keys
        mapped = GitHub.map_thread_entry(item, "review-comment")
        expected.nil? ? assert_nil(mapped[:line]) : assert_equal(expected, mapped[:line])
      end
    end
  end

  def test_explicit_limit_keeps_newest_entries_from_the_complete_merged_thread
    GitHub.stub(:request, lambda { |_config, path, token:| pr_pages.fetch(path) }) do
      thread = GitHub.item_thread(build_config, "token", "one", "repo", 7, "pr", 3)
      assert_equal [4, 5, 6], thread.map { |item| item[:id] }
      assert_equal ["review", "review-comment", "comment"], thread.map { |item| item[:kind] }
    end
  end

  def test_explicit_limit_can_exceed_one_hundred
    path = "/repos/one/repo/issues/7/comments?per_page=100"
    pages = {
      path => response((1..100).map { |id| entry(id) }, "#{path}&page=2"),
      "#{path}&page=2" => response((101..150).map { |id| entry(id) })
    }
    GitHub.stub(:request, lambda { |_config, requested, token:| pages.fetch(requested) }) do
      thread = GitHub.item_thread(build_config, "token", "one", "repo", 7, "issue", 120)
      assert_equal (31..150).to_a, thread.map { |item| item[:id] }
    end
  end

  def test_nonpositive_limit_returns_empty_without_requests
    GitHub.stub(:request, ->(*) { flunk "no request expected" }) do
      [0, -1].each do |limit|
        assert_empty GitHub.item_thread(build_config, "token", "one", "repo", 7, "pr", limit)
      end
    end
  end

  def test_repeated_paginated_fetch_uses_real_rest_cache_without_network
    config = build_config
    pages = pr_pages
    calls = []
    http = Object.new
    http.define_singleton_method(:request) do |request|
      calls << request.path
      page = pages.fetch(request.path)
      result = Net::HTTPOK.new("1.1", "200", "OK")
      result.instance_variable_set(:@read, true)
      result.instance_variable_set(:@body, JSON.generate(page.data))
      page.headers.each { |key, value| result[key] = value }
      result
    end

    first = nil
    Net::HTTP.stub(:start, lambda { |*_, &block| block.call(http) }) do
      first = GitHub.item_thread(config, "token", "one", "repo", 7, "pr")
    end
    assert_equal [1, 2, 3, 4, 5, 6], first.map { |item| item[:id] }
    assert_equal pages.keys.sort, calls.sort

    Net::HTTP.stub(:start, ->(*) { flunk "fresh cached pages must not use network" }) do
      assert_equal first, GitHub.item_thread(config, "token", "one", "repo", 7, "pr", nil)
      assert_equal first.last(2), GitHub.item_thread(config, "token", "one", "repo", 7, "pr", 2)
    end
  end

  private

  def pr_pages
    comments = "/repos/one/repo/issues/7/comments?per_page=100"
    reviews = "/repos/one/repo/pulls/7/reviews?per_page=100"
    inline = "/repos/one/repo/pulls/7/comments?per_page=100"
    {
      comments => response([entry(1, date: "2026-05-01T10:00:00Z")], "#{comments}&page=2"),
      "#{comments}&page=2" => response([entry(6, date: "2026-05-06T10:00:00Z")]),
      reviews => response([entry(2).merge(submitted_at: "2026-05-02T10:00:00Z", state: "APPROVED")], "#{reviews}&page=2"),
      "#{reviews}&page=2" => response([entry(4).merge(submitted_at: "2026-05-04T10:00:00Z", state: "COMMENTED")]),
      inline => response([entry(3, date: "2026-05-03T10:00:00Z").merge(path: "lib/code.rb", line: 42)], "#{inline}&page=2"),
      "#{inline}&page=2" => response([entry(5, date: "2026-05-05T10:00:00Z").merge(in_reply_to_id: 3, side: "RIGHT")])
    }
  end

  def entry(id, date: "2026-05-06T10:00:00Z")
    {
      id: id, body: "Body #{id}", created_at: date,
      html_url: "https://github.com/one/repo/issues/7#comment-#{id}",
      user: { login: "user#{id}", avatar_url: "https://avatars.githubusercontent.com/u/#{id}",
              html_url: "https://github.com/user#{id}" }
    }
  end

  def response(items, next_path = nil, previous: nil)
    links = []
    links << "<https://api.github.com#{previous}>; rel=\"prev\"" if previous
    links << "<https://api.github.com#{next_path}>; rel=\"next\"" if next_path
    GitHub::Response.new(data: items, headers: { "link" => links.join(", ") }, status: 200)
  end
end
