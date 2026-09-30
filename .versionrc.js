// Release configuration for commit-and-tag-version.
// RepoBar keeps its application version in the README release line so a
// release updates the published current-release statement automatically.

const releaseLine = {
  filename: 'README.md',
  updater: {
    readVersion(contents) {
      const match = contents.match(/Current release: `v([^`]+)`/);
      return match ? match[1] : null;
    },
    writeVersion(contents, version) {
      return contents.replace(/(Current release: `v)[^`]+(`)/, `$1${version}$2`);
    },
  },
};

module.exports = {
  packageFiles: [releaseLine],
  bumpFiles: [releaseLine],
  tagPrefix: 'v',
  releaseCommitMessageFormat: 'chore(release): {{currentTag}}',
  commitUrlFormat: 'https://github.com/blackopsrepl/repobar/commit/{{hash}}',
  compareUrlFormat: 'https://github.com/blackopsrepl/repobar/compare/{{previousTag}}...{{currentTag}}',
};
