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

Branch `feat/m31-0.4.0`, from master 6313d91. gitui is built with m31
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
