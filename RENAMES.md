# gitui 0.9.0: syntax library

Version 0.9.0, from master 5b9a2a1 (0.8.0). No module was renamed or removed.
tui is re-pinned to 0.8.0, whose `TUI_syntax` is an adapter over the new
`syntax` library (77 languages, tree-sitter-checked token classes, markdown
fences, HTML/Vue script and style injection). Diffs, blame, file history,
stash and conflict views are highlighted in every language the library knows;
`NO_COLOR`, `GITUI_SYNTAX=off` and `C` still switch it off.

# gitui 0.8.0: sections, folding and a statusline

Version 0.8.0, from master fe1e39a (0.7.0). No module was renamed or removed;
three modules were added. tui is re-pinned to 0.7.0 (`TUI_diff_view` hunks
fold).

- **New keys.** Outline: `[` / `]` previous / next section header, `{` / `}`
  previous / next row at the same depth, `Tab` fold (on a leaf: its section),
  `-` fold every section, `+` / `=` unfold every section. Diff view: `[` / `]`
  previous / next hunk, `{` / `}` previous / next file of the list, `Tab` fold
  the hunk, `-` / `+` fold / unfold all hunks. Everywhere: `i`, the overview.
  None of the existing keys moved.
- **The statusline** is the frame's top border (it replaced the repository
  name that was the frame title there): branch or detached commit, upstream
  with ahead/behind, operation under way, stash count, change counts,
  repository name. The message row at the bottom no longer falls back to
  `on main @ 1a2b3c4 [ahead 2]` when there is no message; it is empty. A test
  or a script that read that text should read the top row instead
  (`tests/pty_blame_undo.py` did and was updated).
- **`gitui.collapsed`** in the repository's config: the folded root section
  ids, written when they change and read at start.
- New modules `ui/GIT_ui_sections.m31` (pure), `ui/GIT_ui_statusline.m31`
  (pure) and `ui/GIT_ui_overview.m31` (the overlay). New `Core` fields:
  `facts`, `folded_saved`, `diff_row_id`; new `Core` methods `repo_path`,
  `repo_name`, `load_folds`, `persist_folds`; `GIT_ui_model.BranchRow` gains
  `ahead`, `behind`, `is_gone`; `RemoteLayer.layer()`. New key-table scope
  `SCOPE_OVERVIEW` and commands `CMD_SECTION_*`, `CMD_SIBLING_*`, `CMD_FOLD`,
  `CMD_FOLD_ALL`, `CMD_UNFOLD_ALL`, `CMD_OVERVIEW`.

# gitui 0.7.0: one build script, syntax highlighting everywhere

Version 0.7.0, from master 383a1b6 (0.6.0). No module was renamed.

- **`scripts/build-gitui.sh` is gone; `scripts/build.sh` builds everything**, as
  the other apps' one script does. No argument builds `gitui.m31` into
  `./ourgitui`; `bash scripts/build.sh git.m31` builds the read-only CLI into
  `./ourgit`; any other `.m31` file builds into `./<its name>`; `-o name`
  renames the output in every case. Anything calling
  `scripts/build-gitui.sh -o X` now calls `scripts/build.sh -o X` (or
  `scripts/build.sh gitui.m31 -o X`). The release workflow and `tests/*.sh` do.
- **Syntax highlighting** in the diff views, the blame view, the commit view
  from the file history, the stash preview and the conflict view, through tui
  0.6.0's `TUI_syntax` (the `deps` pin moves to it). New module
  `ui/GIT_ui_highlight.m31`; new key `C` (toggle); `NO_COLOR`,
  `GITUI_SYNTAX=off` and `git config gitui.syntax off` start it off. See the
  README's "Syntax highlighting".
- The commit view (`GIT_ui_show`) now also colours `+`/`-` lines and hunk
  headers, which it drew plain before; `GIT_ui_blame.BlameOverlay.format` is
  now `margin_text` (the code is drawn separately, coloured).

# gitui 0.6.0: modules grouped into folders

The 66 library modules that sat at the repository root moved into four folders.
Nothing was renamed: module names, the `GIT_` prefix and every public name are
unchanged, so only the `import` line changes. Use `m31c fmt -r .` afterwards to
re-sort imports. tui is re-pinned to v0.5.0 (`1609d91`), whose own modules moved
into `core/`, `widgets/` and `app/` (see tui's RENAMES.md).

```
import GIT_object;        ->  import core.GIT_object;
GIT_object.read(...)      ->  GIT_object.read(...)       (unchanged)
```

A flat import of a moved module is now an error.

Placements decided by the import graph rather than by name: `GIT_client` is in
`ui/` (it imports every `GIT_ui_*` module), `GIT_watch` is in `core/` (it imports
only ignore and index), `GIT_undo` is in `diff/`, and config, reflog, revparse,
branches and checkout are in `core/`.

| module | new import path |
|---|---|
| `GIT_branches` | `core.GIT_branches` |
| `GIT_checkout` | `core.GIT_checkout` |
| `GIT_config` | `core.GIT_config` |
| `GIT_graph` | `core.GIT_graph` |
| `GIT_hash` | `core.GIT_hash` |
| `GIT_ident` | `core.GIT_ident` |
| `GIT_ignore` | `core.GIT_ignore` |
| `GIT_index` | `core.GIT_index` |
| `GIT_log` | `core.GIT_log` |
| `GIT_object` | `core.GIT_object` |
| `GIT_pack` | `core.GIT_pack` |
| `GIT_pack_write` | `core.GIT_pack_write` |
| `GIT_pathtree` | `core.GIT_pathtree` |
| `GIT_reflog` | `core.GIT_reflog` |
| `GIT_refs` | `core.GIT_refs` |
| `GIT_repository` | `core.GIT_repository` |
| `GIT_revparse` | `core.GIT_revparse` |
| `GIT_status` | `core.GIT_status` |
| `GIT_watch` | `core.GIT_watch` |
| `GIT_zlib` | `core.GIT_zlib` |
| `GIT_blame` | `diff.GIT_blame` |
| `GIT_diff3` | `diff.GIT_diff3` |
| `GIT_filelog` | `diff.GIT_filelog` |
| `GIT_hunks` | `diff.GIT_hunks` |
| `GIT_merge` | `diff.GIT_merge` |
| `GIT_patch` | `diff.GIT_patch` |
| `GIT_rebase` | `diff.GIT_rebase` |
| `GIT_rebase_todo` | `diff.GIT_rebase_todo` |
| `GIT_sequencer` | `diff.GIT_sequencer` |
| `GIT_stash` | `diff.GIT_stash` |
| `GIT_udiff` | `diff.GIT_udiff` |
| `GIT_undo` | `diff.GIT_undo` |
| `GIT_xdiff` | `diff.GIT_xdiff` |
| `GIT_http_fetch` | `net.GIT_http_fetch` |
| `GIT_http_push` | `net.GIT_http_push` |
| `GIT_pull` | `net.GIT_pull` |
| `GIT_remote` | `net.GIT_remote` |
| `GIT_ssh_transport` | `net.GIT_ssh_transport` |
| `GIT_wire` | `net.GIT_wire` |
| `GIT_client` | `ui.GIT_client` |
| `GIT_ui_autorefresh` | `ui.GIT_ui_autorefresh` |
| `GIT_ui_blame` | `ui.GIT_ui_blame` |
| `GIT_ui_branch` | `ui.GIT_ui_branch` |
| `GIT_ui_commit` | `ui.GIT_ui_commit` |
| `GIT_ui_core` | `ui.GIT_ui_core` |
| `GIT_ui_diff` | `ui.GIT_ui_diff` |
| `GIT_ui_filelog` | `ui.GIT_ui_filelog` |
| `GIT_ui_help` | `ui.GIT_ui_help` |
| `GIT_ui_lines` | `ui.GIT_ui_lines` |
| `GIT_ui_log` | `ui.GIT_ui_log` |
| `GIT_ui_loop` | `ui.GIT_ui_loop` |
| `GIT_ui_merge` | `ui.GIT_ui_merge` |
| `GIT_ui_merge_model` | `ui.GIT_ui_merge_model` |
| `GIT_ui_model` | `ui.GIT_ui_model` |
| `GIT_ui_outline` | `ui.GIT_ui_outline` |
| `GIT_ui_panel` | `ui.GIT_ui_panel` |
| `GIT_ui_picker` | `ui.GIT_ui_picker` |
| `GIT_ui_prompt` | `ui.GIT_ui_prompt` |
| `GIT_ui_rebase` | `ui.GIT_ui_rebase` |
| `GIT_ui_remote` | `ui.GIT_ui_remote` |
| `GIT_ui_search` | `ui.GIT_ui_search` |
| `GIT_ui_sequencer` | `ui.GIT_ui_sequencer` |
| `GIT_ui_show` | `ui.GIT_ui_show` |
| `GIT_ui_stash` | `ui.GIT_ui_stash` |
| `GIT_ui_tags` | `ui.GIT_ui_tags` |
| `GIT_ui_undo` | `ui.GIT_ui_undo` |

---

# gitui -> m31 naming convention: renames

Branch `naming/migrate`, from master 644ab69 (the v0.2.0 project layout). The
rules are `docs/naming-decision.md` §3 and §8 in the m31 repo: snake_case values
and functions, `PREFIX_name` modules, names of three letters or more, no
clipped words, and a `bool` field, parameter or function starts with
is_/has_/can_/should_/did_/was_/needs_/will_.

Everything below that is `pub` is a public name; the rest is listed only so a
grep for the old name finds its replacement.

## Modules (files, imports, qualified uses)

| old | new |
|---|---|
| `checkout` | `GIT_checkout` |
| `gitclient` | `GIT_client` |
| `gitconfig` | `GIT_config` |
| `gitignore` | `GIT_ignore` |
| `gitlog` | `GIT_log` |
| `httpfetch` | `GIT_http_fetch` |
| `httppush` | `GIT_http_push` |
| `hunks` | `GIT_hunks` |
| `index` | `GIT_index` |
| `object` | `GIT_object` |
| `pack` | `GIT_pack` |
| `packwrite` | `GIT_pack_write` |
| `patch` | `GIT_patch` |
| `pull` | `GIT_pull` |
| `refs` | `GIT_refs` |
| `repo` | `GIT_repository` |
| `sha1` | `GIT_sha1` |
| `status` | `GIT_status` |
| `zlib` | `GIT_zlib` |

`git.m31` and `gitui.m31` (the two entry points) keep their names. The tui
modules gitui imports are renamed on tui's side (`tuiapp` -> `TUI_app` and so
on); see tui's `RENAMES.md`.

## Public fields (break constructor calls with named arguments and every `.field` access)

| module | type | old | new |
|---|---|---|---|
| GIT_checkout | Branch | current | is_current |
| GIT_client | CommitFileDiff | binary | is_binary |
| GIT_http_fetch | Packet | flush | is_flush |
| GIT_http_fetch | DemuxResult | remote_error | has_remote_error |
| GIT_http_push | Report | unpacked | is_unpacked |
| GIT_http_push | Report | ok | is_ok |
| GIT_index | Entry | assume_valid | is_assume_valid |
| GIT_pull | Outcome | moved | has_moved |

## Public functions and methods

| module | old | new |
|---|---|---|
| GIT_client | State.stage_hunk | State.did_stage_hunk |
| GIT_client | State.unstage_hunk | State.did_unstage_hunk |
| GIT_refs | exists | has_ref |
| GIT_repository | per_worktree | is_per_worktree |

## Public parameters (break only callers that pass the argument by name)

| module | function | old | new |
|---|---|---|---|
| GIT_client | build_outline | st | status |
| GIT_client | State.stage_path, State.unstage_path, State.discard_path | rel | relative_path |
| GIT_client | State.stage_hunk, State.unstage_hunk | rel | relative_path |
| GIT_client | State.stage_hunk, State.unstage_hunk | k | hunk_index |
| GIT_client | State.draw | buf | buffer |
| GIT_client | State.handle | ev | event |
| GIT_http_fetch | read_packet | buf | buffer |
| GIT_http_fetch | read_packet | at | offset |
| GIT_http_fetch | fetch | ad | advertisement |
| GIT_http_push | auth_header, discover, push | r | remote |
| GIT_index | from_stat | st | stat |
| GIT_index | write, encode | ix | index |
| GIT_object | is_name | s | name_text |
| GIT_object | write_commit | c | commit |
| GIT_pack_write | entry_header | type_num | type_code |
| GIT_patch | apply_hunk, revert_hunk | k | hunk_index |
| GIT_pull | pull | r | remote |
| GIT_zlib | inflate, inflate_at, decompress, decompress_at | src | source |

## Private functions (no consumer impact)

| module | old | new |
|---|---|---|
| GIT_checkout | plausible_branch_name | is_plausible_branch_name |
| GIT_checkout | parent_dir | parent_directory |
| GIT_checkout | same_bytes | is_same_bytes |
| GIT_client | bytes_eq | is_bytes_equal |
| GIT_client | expanded_for | is_expanded_for |
| GIT_client | find_dir | find_directory |
| GIT_client | State.ensure_commit_changes | State.did_compute_commit_changes |
| GIT_client | State.write_worktree | State.did_write_worktree |
| GIT_client | State.head_has | State.is_in_head_tree |
| GIT_client | State.set_index_blob | State.did_set_index_blob |
| GIT_client | State.drop_index_entry | State.did_drop_index_entry |
| GIT_client, GIT_http_fetch, GIT_refs | dir_of | directory_of |
| GIT_config | header_matches | is_matching_header |
| GIT_http_fetch | len_hex | length_hex |
| GIT_http_fetch, GIT_index, GIT_object, GIT_pack | hex_val | hex_value |
| GIT_ignore | matched | is_path_matched |
| GIT_ignore | match_segments | is_matching_segments |
| GIT_ignore | seg_match | is_segment_match |
| GIT_pack | parse_idx | parse_index |
| GIT_pull | have | has_object |
| GIT_refs | safe_name | is_safe_name |
| git.m31 | blank_octet | is_blank_octet |
| tests/t_push.m31 | bool_text(flag) | bool_text(is_true) |

## Private constants, fields, parameters and locals

| module | old | new |
|---|---|---|
| GIT_client | COMMIT_BODY_WRAP_COLS | COMMIT_BODY_WRAP_COLUMNS |
| GIT_client | commit_msg_path (field) | commit_message_path |
| GIT_client | head_msg | head_message |
| GIT_client | cols | columns |
| GIT_ignore | IgnoreFile.base_segs | base_segments |
| GIT_ignore | rel (str / List) | relative_path / relative_segments |
| GIT_ignore | is_dir (parameter) | is_directory |
| GIT_pack | idx_path (field) | index_path |
| GIT_pack | header_len (field) | header_length |
| GIT_pack_write | type_num (parameter) | type_code |

Earlier passes of this branch (commits 5c074cb to 61815dd) renamed several
hundred locals, parameters, `case` payloads and loop variables, and spelled out
clipped words (rel, sym, hdr, hay, rep, oid, nid, segs, pat) the lint's table
did not yet cover; none of those are public beyond the tables above.

## Names taken from tui

gitui now uses tui's second-pass names: `Cell.symbol`, `Node.is_expanded` (and
the `is_expanded:` named argument of `Node.section`), `Paragraph.should_wrap`,
`Buffer.symbol_at`/`append_symbol`/`is_inside`/`is_same_cell`/`is_same_row`,
`Rect.has_point`, `TUI_geometry.columns`, `TUI_app.has_resized`,
`JumpList.did_activate`/`did_select_id`, `Outline.did_select_id`. Of these gitui
calls `Node.is_expanded`, `Node.section(is_expanded:)`, `Outline.did_select_id`,
`JumpList.did_activate` and `TUI_geometry.columns`.

## Unchanged on purpose

String literals: status-line messages, trap messages, test labels, the command
names the test programs take on their command line (`stage_hunk`,
`unstage_hunk`), and every on-disk or on-wire format.

## Documentation

References to the m31 monorepo's `apps/git`, `apps/tui` and `apps/markdown`
(deleted when these repos were extracted) now name this repo's own files
(`tests/`, `scripts/`) or the `tui` package; `tests/test.sh` no longer mentions a
separate `TUI_ROOT` checkout, since `deps` pins tui.

---

# 0.5.0: m31 0.4.0 layout and naming

Branch `feat/m31-0.4.0`, from master 6313d91 (0.5.0). gitui is built with m31
v0.4.0, which groups the standard library into folders and makes `m31c lint` a
gate. `m31c lint .` reports no findings and `m31c fmt --check -r .` is clean;
behaviour, the command line and the key bindings are unchanged.

## Imports and standard library

Standard library imports use the group path (`import net.http;`,
`import encoding.base64;`, `import crypto.sha256;`, `import ssh.sshclient;`
and so on). The standard library renames gitui calls:

| old | new |
|---|---|
| `fs.exists` | `fs.is_present` |
| `fs.is_dir` | `fs.is_directory` |
| `os.args` | `os.arguments` |
| `os.ExitStatus.success` | `os.ExitStatus.is_success` |
| `term.fg` / `term.bg` | `term.foreground` / `term.background` |
| `term.Size.cols` | `term.Size.columns` |
| `args.Parsed.flag` | `args.Parsed.is_flag_set` |
| `sshexec.Channel.read_all_err` | `sshexec.Channel.read_all_error` |

## Public fields (break named arguments and every `.field` access)

| module | type | old | new |
|---|---|---|---|
| GIT_blame | Line | boundary | is_boundary |
| GIT_merge | StartOpts | ff | fast_forward |
| GIT_merge | StartOpts | allow_unrelated | is_unrelated_allowed |
| GIT_rebase | PlanOpts | root | is_root |
| GIT_rebase | PlanOpts | keep_base | should_keep_base |
| GIT_rebase | PlanOpts | interactive | is_interactive |
| GIT_rebase | PlanOpts | autosquash | should_autosquash |
| GIT_rebase | Plan | root | is_root |
| GIT_rebase | Plan | up_to_date | is_up_to_date |
| GIT_rebase | StartOpts | interactive | is_interactive |
| GIT_rebase | StartOpts | autostash | should_autostash |
| GIT_rebase | State | interactive | is_interactive |
| GIT_sequencer | Options | no_commit | should_skip_commit |
| GIT_sequencer | Options | record_origin | should_record_origin |
| GIT_sequencer | Options | allow_empty | is_empty_allowed |
| GIT_sequencer | Options | keep_redundant | should_keep_redundant |
| GIT_sequencer | Options | as_range | is_range |
| GIT_sequencer | State | stopped | is_stopped |
| GIT_ssh_transport | Upload, Receive | conn | connection |
| GIT_stash | Item | n | index |
| GIT_xdiff | Edit | a_len | a_length |
| GIT_xdiff | Edit | b_len | b_length |

## Public functions, methods and constants

| module | old | new |
|---|---|---|
| GIT_blame | Quiet.step, `Progress.step` | Quiet.should_continue, `Progress.should_continue` |
| GIT_config | Config.has | Config.has_key |
| GIT_config | commit_gpgsign | is_commit_gpgsign_enabled |
| GIT_config | push_auto_setup_remote | is_push_auto_setup_remote_enabled |
| GIT_config | rerere_enabled | is_rerere_enabled |
| GIT_hash | SHA1_LEN / SHA256_LEN | SHA1_LENGTH / SHA256_LENGTH |
| GIT_hash | raw_len | raw_length |
| GIT_hash | hex_len | hex_length |
| GIT_object | hex_len | hex_length |
| GIT_ignore | path_glob | is_path_glob_match |
| GIT_merge | in_progress | is_in_progress |
| GIT_merge | message_file_is_current | is_message_file_current |
| GIT_rebase | state_dir | state_directory |
| GIT_rebase | in_progress | is_in_progress |
| GIT_rebase | default_autostash | is_autostash_default |
| GIT_rebase | default_autosquash | is_autosquash_default |
| GIT_reflog | exists | has_log |
| GIT_remote | glob_matches | is_glob_match |
| GIT_sequencer | sequencer_dir | sequencer_directory |
| GIT_sequencer | in_progress | is_in_progress |
| GIT_ssh_transport | hashes_known_hosts | should_hash_known_hosts |
| GIT_ui_autorefresh | AutoRefresh.tick, `Ticker.tick` | AutoRefresh.did_change_on_tick, `Ticker.did_change_on_tick` |
| GIT_ui_core | CMD_PREV | CMD_PREVIOUS |
| GIT_ui_merge | MergeLayer.take_dirty | MergeLayer.did_take_dirty |
| GIT_ui_merge | MergeLayer.stage_resolved | MergeLayer.did_stage_resolved |
| GIT_ui_merge | MergeLayer.take_whole | MergeLayer.did_take_whole |
| GIT_ui_rebase | RebaseLayer.describe | RebaseLayer.needs_message_after_describing |
| GIT_ui_rebase | RebaseLayer.write_message_file | RebaseLayer.did_write_message_file |
| GIT_ui_rebase | RebaseLayer.run_editor | RebaseLayer.did_run_editor |
| GIT_watch | DIR_CAP | DIRECTORY_CAP |

## Public parameters (break calls with named arguments)

| function | old | new |
|---|---|---|
| GIT_stash.push | include_untracked, keep_index, store | should_include_untracked, should_keep_index, should_store |
| GIT_stash.show | include_untracked | should_include_untracked |
| GIT_stash.apply, GIT_stash.pop | restore_index | should_restore_index |
| GIT_refs.update | msg | reflog_message |
| GIT_reflog.delete | rewrite | should_rewrite |
| GIT_sequencer.write_todo, read_todo, read_options, write_options | dir | directory |
| GIT_ui_stash.push_stash, apply_stash | include_untracked, keep_index, restore_index, drop_after | should_include_untracked, should_keep_index, should_restore_index, should_drop_after |
| GIT_ui_remote.push_with, record_pushed, push_over_ssh | set_upstream | should_set_upstream |
| GIT_ui_rebase.continue_rebase_now | skip | should_skip |

Positional parameters renamed without a new meaning (`msg` -> `message`,
`n` -> `count` / `number`, `a` / `b` -> `first` / `second` or `lines_a` /
`lines_b`, `lo` / `hi` -> `first_index` / `end_index`) do not break callers
unless they pass the argument by name.

## Everything else

Private functions, fields, locals and `case` bindings follow the same rules
(booleans take is_/has_/did_/should_, abbreviations are spelled out, unused
`case` payloads are `_`, `Err` payloads are `error`); a grep for the old name
finds nothing, and the diff shows the new one. String literals, command names
the test programs take, and every on-disk or on-wire format are unchanged.
