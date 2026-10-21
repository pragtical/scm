# Source Control Management Plugin

Source control integration for Pragtical with Git and Fossil support. Review
diffs, stage changes, create commits, and manage repositories inside the editor.

## Usage and Requirements

Requires Pragtical 3.14.0 or newer and the matching updated `widget` plugin.
Pragtical v3.13.1 and older are not supported.

You will need to have the SCM binaries installed and accessible from
your `PATH` environment variable:

* [git] - for projects versioned in git
* [fossil] - for projects versioned in fossil
* [language_diff] plugin - optional but recommended

Follow the usual plugin installation procedure. Git and Fossil repositories
are detected automatically when opening projects.

Common SCM commands are available under **Tools > Source Control** and in the
command palette.

For illustrated workflows and a command reference, see the
[SCM Manual](https://pragtical.dev/docs/plugins/scm).

## Features

* Integrated repository workbench with searchable changes, staged changes,
  history, branches, tags, and stashes.
  - Numbered unified and side-by-side text diffs with syntax highlighting.
  - Git file, hunk, and selected-line staging and unstaging.
  - Partially staged files appear in both working-tree and index views.
  - Git commit graph and bounded history loading.
  - Save, inspect, apply, and delete Git and Fossil stashes.
  - Continue or abort interrupted Git merge, rebase, cherry-pick, and revert
    operations after resolving files in the editor.
* Support for multiple projects.
* Detect missing SCM binaries and allow configuring Git and Fossil binary paths.
* Show the current branch and change statistics on the status bar.
  - Inserted, modified, and deleted line counts are colorized with diff colors.
* View the current project diff in a read-only viewer by executing the
  `scm:global-diff` command or right-clicking the status bar SCM item.
* View the current project status by executing `scm:project-status`.
* Colorize treeview files depending on the item status, which can be:
  - added
  - renamed
  - deleted
  - edited
  - untracked
* Draw file changes in document gutters, including:
  - additions
  - deletions
  - modifications
* Display blame information for active document line.
  - View the diff changes for the associated commit.
  - Resizable commit details below the active document with Copy Hash and
    View Diff actions, without taking focus from the editor.
  - Choose Bottom Pane (default) or Floating Popup using **Blame Display** in
    **Settings > Plugins > Source Control Management**.
* View the searchable commit history list for the entire project, for a
  specific file or directory path, or for a selected branch or tag.
  - View the diff of any commit on the list.
  - Copy the commit hash.
  - Cherry-pick a commit into the current checkout when supported by the
    backend.
  - If a file compare the commit with current file.
  - Amend the current commit from the latest history entry.
  - Commit diffs show a compact subject header. Expand it to read the full
    message, author, date, and hash. Long bodies scroll without covering the
    patch. This also applies to workbench and repository-tool commit previews;
    plain text comparisons retain the full commit message.
* Create commits with a dedicated commit-message editor.
  - The editor shows repository status as comments that are stripped before
    committing.
  - The first line is highlighted when it exceeds the recommended length.
  - Subsequent lines are wrapped to the recommended body length.
* Amend the current commit with `scm:amend-current-commit`.
* Pull changes with credentials input when the backend requires it.
  - Git divergent-pull errors can prompt for merge, rebase, or fast-forward-only
    strategy.
  - The selected Git pull strategy can be remembered for the repository.
* Push changes with credentials input when the backend requires it.
  - Git opens a dialog prefilled with the current local branch and its default
    push remote and destination. Override either branch or the remote, optionally
    set upstream tracking, or confirm a force-with-lease push.
  - Fossil retains its repository-wide push operation.
* Fetch remote refs from branch and tag views.
  - Backends that support pruning can ask whether locally cached deleted remote
    refs should be pruned.
* Manage branches from a searchable branches list.
  - Create branches from a selected base branch.
  - Optionally check out a branch after creation.
  - Check out, delete, or force-delete branches.
  - View branch history and branch changes diff.
  - View commits on a branch that are not on the current checkout.
  - Copy the latest commit hash.
  - Rebase a branch onto another branch when supported by the backend.
* Manage tags from a searchable tags list.
  - Create lightweight or annotated tags from a selected commit.
  - Edit a tag target and applicable metadata.
  - Check out or delete tags.
  - View tag history and tag changes diff.
  - Copy the tag commit hash.
* Add, remove, move, restore, stage, and unstage paths when supported by the
  backend.
* View file diffs with `scm:file-diff` and compare files with HEAD.
* Navigate between document changes with `scm:goto-previous-change` and
  `scm:goto-next-change`.

## Repository Workbench

Run `scm:workbench` (`Ctrl+Shift+G`), use **Tools > Source Control**, or choose
**Repository Workbench** from a project tree context menu. Existing commands
and standalone history, branch, and tag views remain available.

Choose a repository and a view, then select a file or commit to inspect its
diff. Changes and Staged Changes are separate views of the working tree and
index. Use the file actions for whole-file staging, click a hunk for hunk
actions, or drag across changed lines for line actions. Partial staging is
limited to ordinary text modifications; use whole-file actions for renames,
binary files, additions, deletions, and mode changes. Fossil has no staging area
and does not offer Git index actions.
Select an untracked file and choose **Add to Repository** to begin tracking it.
Git also stages the new file; Fossil records it as an added checkout file.

Filters accept plain terms, quoted phrases, exclusions such as `-message:wip`,
and `author:`, `message:`, `hash:`, `ref:`, `path:`, and `status:` fields. History
starts with 200 commits; **Load More** increases the limit. Graph lanes are
hidden while filtering so excluded commits do not imply false ancestry.
In History, choose **View Diff** or double-click a commit to open its complete
comparison in the configured diff viewer, including the changed-files list in
Advanced mode. Single-clicking retains the inline preview.

Stashing saves tracked work-in-progress changes. Applying a stash keeps its
saved copy; deletion is a separate confirmed action. Repository mutations can
fail on conflicts or stale patches and display the backend's error. Resolve
conflicts in the editor and stage the resolved files before continuing Git
operations. Abort actions ask for confirmation because resolutions can be lost.

Narrow editor panes use stacked lists and previews with compact view and action
selectors. The advanced viewer includes empty added/deleted files, binary
notices, renames, copies, and permission or file-type changes. Fossil displays
committed renames as additions and deletions. Git merge commits are compared
against their first parent.

External edits in collapsed folders may not be detected until the folder is
reopened or another editor or SCM event triggers a refresh. Repository refreshes
also update open-document gutters, tab status, and enabled blame without
discarding unsaved edits.

### Repository Tools

Open `scm:repository-tools` or the workbench's **Tools** action. Available
views and operations follow backend capabilities:

* Manage remotes with `scm:manage-remotes`: add or remove remotes and edit URLs.
  Git supports rename, separate fetch/push URLs, and resetting push-URL fallback.
  Additional configured URLs are preserved when the first URL is edited.
  Fossil supports named remotes and selecting its sync default; removing that
  default disables autosync, with a confirmation warning.
* Incoming and outgoing commit lists compare Git with the configured upstream.
  Fetch updates these refs; select a commit to review its diff or copy its hash.
  Fossil synchronizes repository-wide and does not offer per-branch ahead/behind
  counts.
* Push a branch with optional upstream tracking, push a tag, or confirm deletion
  of a remote ref. Branch and tag context menus expose the same actions.
  Force-with-lease shows and pins an expected tip before confirmation, protecting
  against changes made while the confirmation is open.
* Merge a source branch into a target with native strategies. Git offers normal,
  fast-forward-only, or conflict preferences. Fossil offers normal/integrate
  merges; the resulting checkout must be committed separately.
* Add or safely remove Git worktrees, open worktrees and submodules as projects,
  initialize submodules recursively, and inspect/download Git LFS files when
  `git-lfs` is installed.
  Worktree destinations use directory browsing with an editable path,
  so Git can create a directory that does not exist yet. Select an existing
  branch or enter a new branch name based on the selected branch.
  Browsing follows Pragtical's **Use System File Picker** setting; otherwise
  it uses the command view.
* Search commit history by author, message, and path. Git additionally supports
  searching changed text with regular expressions.
* Review an oldest-to-newest local rewrite plan, reorder commits, or mark them
  pick/squash/drop. Rewriting requires a clean, attached checkout, rejects merges
  and commits reachable from known remote-tracking refs, and creates a
  `scm-backup/...` branch. Fetch and review remote state before rewriting;
  locally cached refs cannot prove a commit has never been shared elsewhere.
  Initial root commits are excluded from this workflow.

The workbench's **Resolve** action opens an editable result with base/ours/theirs
sources and per-block choices. Narrow panes show one selectable source at a time.
**Save / Resolve** refuses remaining conflict markers and stages Git resolutions.
Git operations can continue, skip where applicable, or abort with confirmation.
Fossil uses normal commit creation and one-level undo; the undo prompt warns that
another undoable command may have replaced the original merge's undo state.
Retained Fossil merge files provide source panes when available. Inline result
editing remains available when those files are absent.

**Review Changes** in the commit-message editor opens a companion workbench for
diff review and staging without losing the message. Stash dialogs can include
untracked Git files and optionally restore index state on application. Fossil
stashes tracked changes and has no index; neither option is presented for it.
Checkout and rebase offer to stash first when there are local changes.

Diff **Options** select context length, full-file context, ignored whitespace,
and trailing-whitespace highlighting. Partial staging is disabled while ignoring
whitespace. **Image / Binary** compares file versions as images or a hex preview
of the first 64 KiB. Text/binary previews are limited to 16 MiB. Editor tabs have
status-colored indicators, configurable with `config.plugins.smc.tab_colors`.
Binary comparison headers stay fixed while hex content scrolls below them.

### Diff Review And Initialization

The default **Advanced** diff viewer lists changed files beside numbered,
syntax-highlighted unified or side-by-side diffs. It handles renamed, deleted,
binary, and mode-only changes, and filters by path or review state. **Viewed**
and **Next Unreviewed** track progress through the current comparison.
**View Text** opens the original complete diff, including its preamble.

Choose **Diff Viewer** under **Settings > Plugins > Source Control Management**
to use the original plain-text view instead. The setting is
`config.plugins.smc.diff_viewer`, with values `advanced` (default) and `text`.
Project, path, commit, branch, and tag diff commands use this preference.

The workbench also supports Viewed marks for pending files. Marks are
session-local and are invalidated when a newly loaded diff differs from the
reviewed version. **Options** sorts changed files by path, status, or filesystem
modification time.

Use `scm:initialize-repository`, the Tools menu, or a non-repository directory's
treeview menu to initialize an existing directory. Select an available backend,
such as Git or Fossil. For Git, choose an initial branch; for Fossil, choose a
new repository file and administrator username.
Existing files remain untouched and untracked. Existing repositories and Fossil
repository files are not overwritten. Adding files and committing are separate
actions. Initialization is unavailable for an existing repository or a directory
inside one, including Git worktrees and bare repositories.

## Credits

Thanks to the authors of [gitdiff], [gitstatus], and [gitblame], whose work
contributed to this plugin.

[git]: https://git-scm.com/
[fossil]: https://www.fossil-scm.org/
[language_diff]: https://github.com/pragtical/plugins/blob/master/plugins/language_diff.lua
[gitdiff]: https://github.com/vincens2005/lite-xl-gitdiff-highlight
[gitstatus]: https://github.com/lite-xl/lite-xl-plugins/blob/master/plugins/gitstatus.lua
[gitblame]: https://github.com/juliardi/lite-xl-gitblame
