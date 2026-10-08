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
