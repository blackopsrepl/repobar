# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  def test_default_config_uses_repobar_paths
    config = RepoBar::Core::Config.default_config

    assert_equal 1, config[:version]
    assert_equal "https://github.com", config.dig(:github, :host)
    assert_equal "https://api.github.com", config.dig(:github, :apiHost)
    assert_equal "gh", config.dig(:github, :authSource)
    assert_equal File.join(Dir.home, ".local", "state", "repobar"), config.dig(:runtime, :stateDir)
    assert_equal File.join(Dir.home, ".repobar", "config.json"), RepoBar::Core::Config.default_config_path
  end

  def test_normalize_filters_invalid_repo_names_and_clamps_values
    config = RepoBar::Core::Config.normalize_config(
      repoList: {
        displayLimit: 0,
        pinnedRepositories: ["OpenClaw/OpenClaw", "bad", "openclaw/openclaw"]
      },
      runtime: {
        refreshSeconds: 1,
        waybarSignal: 0
      }
    )

    assert_equal 5, config.dig(:repoList, :displayLimit)
    assert_equal ["openclaw/openclaw"], config.dig(:repoList, :pinnedRepositories)
    assert_equal 30, config.dig(:runtime, :refreshSeconds)
    assert_equal 10, config.dig(:runtime, :waybarSignal)
  end

  # RepoBar is GitHub-only. A leftover Forgejo config must not survive as a dead
  # endpoint, and must not carry a non-https host into the REST client.
  def test_non_github_hosts_fall_back_to_github_defaults
    config = RepoBar::Core::Config.normalize_config(
      github: {
        provider: "forgejo",
        host: "http://vigilance:3002",
        apiHost: "http://vigilance:3002/api/v1",
        authSource: "env"
      }
    )

    assert_nil config.dig(:github, :provider)
    assert_equal "https://github.com", config.dig(:github, :host)
    assert_equal "https://api.github.com", config.dig(:github, :apiHost)
    assert_equal "env", config.dig(:github, :authSource)
    assert_empty RepoBar::Core::Config.validate_config(config).select { |issue| issue[:severity] == "error" }
  end

  def test_insecure_api_host_is_normalized_away
    config = RepoBar::Core::Config.normalize_config(
      github: { host: "https://ghe.example.com", apiHost: "http://ghe.example.com/api/v3" }
    )

    assert_equal "https://api.github.com", config.dig(:github, :apiHost)
    assert_equal "https://ghe.example.com", config.dig(:github, :host)
  end

  def test_validate_config_rejects_unknown_auth_source
    config = RepoBar::Core::Config.normalize_config(github: { authSource: "token-file" })
    issues = RepoBar::Core::Config.validate_config(config)

    assert_equal ["error"], issues.select { |issue| issue[:field] == "github.authSource" }.map { |issue| issue[:severity] }
  end
end
