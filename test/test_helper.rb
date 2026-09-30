# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "tmpdir"
require "repobar"

module RepoBarTestHelpers
  def build_config(state_dir: Dir.mktmpdir)
    RepoBar::Core::Config.normalize_config(
      runtime: {
        stateDir: state_dir,
        quickShellShell: File.expand_path("../frontend/quickshell/shell.qml", __dir__)
      },
      repoList: {
        displayLimit: 3
      },
      localProjects: {
        roots: [],
        maxDepth: 2
      }
    )
  end

  # Writes a real config file so daemon/store paths exercise the same load/save
  # round trip the CLI uses.
  def write_test_config(overrides = {})
    dir = Dir.mktmpdir
    path = File.join(dir, "config.json")
    config = RepoBar::Core::Config.normalize_config(
      { runtime: { stateDir: File.join(dir, "state") }, localProjects: { roots: [] } }.merge(overrides)
    )
    RepoBar::Core::Config.save_config(config, path)
    path
  end

  def sample_repo(name: "openclaw/openclaw", prs: 2, issues: 3, ci: "passing", dirty: false)
    owner, repo_name = name.split("/", 2)
    {
      id: name,
      fullName: name,
      owner: owner,
      name: repo_name,
      description: "sample",
      url: "https://github.com/#{name}",
      private: false,
      fork: false,
      archived: false,
      updatedAt: Time.now.utc.iso8601,
      stats: {
        stars: 10,
        forks: 1,
        pushedAt: Time.now.utc.iso8601,
        openIssues: issues,
        openPulls: prs
      },
      ciStatus: ci,
      local: dirty ? {
        path: "/tmp/#{repo_name}",
        fullName: name,
        branch: "main",
        dirty: true,
        dirtyCount: 2,
        ahead: 1,
        behind: 0
      } : nil
    }
  end
end

class Minitest::Test
  include RepoBarTestHelpers
end
