# Retired performance worktrees

The two worktree branch tips were already ancestors of main. Their uncommitted
patches are preserved here, together with the exact base commits, rather than
being activated in production.

- `share-captureless.patch` borrows a callable from another Context without
  assigning a destination identity. Independent Context identity counters can
  collide, breaking function equality and table keys. Its pointer-sharing test
  does not establish semantic safety.
- `lazy-captures.patch` delays native-environment rejection beyond the module
  fallback boundary and does not retain the source Context needed to materialize
  deferred captures safely. Later unaccepted experiments attempted additional
  source-ownership and rejection handling. This older patch is not suitable for
  transplanting into current main.

To inspect either prototype, apply its patch to its recorded base in a disposable
checkout. Neither patch is a recommended optimization.

Desktop worktree commits 16d0052, 65a0350 and 5211f1e were verified patch-identical
to main commits 83635f1, 8243acc and 7a2b483 respectively. The desktop main branch
also contains newer documentation and fixture corrections. Android had no extra
worktrees or uncommitted changes.
