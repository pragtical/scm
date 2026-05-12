# Source Control Management Plugin

This plugin provides base functionality that allows you to easily add support
for any source control management system while saving you from having to
re-implement editor integration. It uses Pragtical `process` api to allow
async calling of the SCM binaries.

You can easily implement your own SCM backend by extending `plugins.scm.backend`,
the plugin will take care of the rest for you. Currently it ships with the
following backends:

* [Git](backend/git.lua)
* [Fossil](backend/fossil.lua)

Any of the backends listed above can serve you as an example or template to
implement your own.

## Usage and Requirements

You will need to have the SCM binaries installed and accesible from
your `PATH` environment variable:

* [git] - for projects versioned in git
* [fossil] - for projects versioned in fossil
* [language_diff] plugin - optional but recommended

Follow the usual plugin installation procedure. When opening projects the
backend will be auto detected by using the backend's `detect()` method. Then
it will be associated to the project for subsequente use.

## Features

* Support for multiple projects.
* Detect missing SCM binaries and allow configuring Git and Fossil binary paths.
* Show the current branch and change statistics on the status bar.
  - Inserted, modified, and deleted line counts are colorized with diff colors.
* View the current project diff in a read-only document by executing the
  `scm:global-diff` command or clicking the status bar SCM item.
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
* View the searchable commit history list for the entire project, for a
  specific file or directory path, or for a selected branch or tag.
  - View the diff of any commit on the list.
  - Copy the commit hash.
  - Cherry-pick a commit into the current checkout when supported by the
    backend.
  - If a file compare the commit with current file.
  - Amend the current commit from the latest history entry.
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

## Credits

Thanks to the authors of [gitdiff], [gitstatus] and [gitblame]
which code served as a source of copy-pasting and inspiration!

[git]: https://git-scm.com/
[fossil]: https://www.fossil-scm.org/
[language_diff]: https://github.com/pragtical/plugins/blob/master/plugins/language_diff.lua
[gitdiff]: https://github.com/vincens2005/lite-xl-gitdiff-highlight
[gitstatus]: https://github.com/lite-xl/lite-xl-plugins/blob/master/plugins/gitstatus.lua
[gitblame]: https://github.com/juliardi/lite-xl-gitblame
