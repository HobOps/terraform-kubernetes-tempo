export default {
  extends: ["@commitlint/config-conventional"],
  // GitHub merge/revert commits are not conventional; ignore them in CI ranges.
  ignores: [
    (message) => /^Merge /m.test(message),
    (message) => /^Revert "/m.test(message),
  ],
};
