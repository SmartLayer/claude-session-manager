# streamtree

## NAME

streamtree - a tree with sortable columns drawn in one Tk text widget

## SYNOPSIS

```tcl
::tcl::tm::path add $dir
package require streamtree

set t [::streamtree::StreamTree new]
$t setup .host                       ;# a frame you created and packed
$t insert "" row a [dict create label "first row"]
```

## DESCRIPTION

`ttk::treeview` cannot draw multi-line rows, embed per-row widgets (match snippets, badge pills), anchor the viewport against a streaming insert, or roll child aggregates up into a parent heading. A canvas rewrite that can is a project of its own.

streamtree renders a tree of abstract nodes into a single `text` widget: nodes nested to any depth, each rendered as one row, with a right-pinned metadata strip whose sortable, resizable columns line up across every row. It reuses treeview's *vocabulary* so the API reads as familiar. Each node carries the position marks and tag that locate it in the widget plus an opaque domain payload; the subclass supplies content and ordering through hooks (Template Method), and the base class never looks inside a payload.

`setup` runs the whole construction ritual: it seeds the base class's state, builds the header and list into the frame, and lays out the columns. A host that wants to assemble things differently can do what `setup` does, step by step. Content beyond a flat labelled list comes from subclassing and overriding hooks (columns, rich subjects, sorts, per-kind row styles).

## PRIMITIVES MAPPED TO ttk::treeview

| streamtree | ttk::treeview | Notes |
|---|---|---|
| `insert parent kind key payload ?-pos {before id}?` | `insert parent index -id ...` | `kind` selects the row's per-node-type hooks (`start_gravity`, `row_tags`, ...); returns a node id; renders now if the node is not hidden and its parent's own row is drawn and open, so a node born under a shut or undrawn ancestor waits in the store until that ancestor opens; `-pos {before id}` seats it before that sibling in the store and the view alike (a sibling the parent does not hold appends), else it goes last |
| `delete id` | `delete id` | removes the node and its subtree from view and store |
| `detach id` | `detach id` | removes the row from view, keeps the node (and its open state) in the store |
| `item id` | `item id -values ...` | rewrites the node's own row in place |
| `expand id` / `collapse id` | `item id -open true/false` | draws / removes the body; `expand` also draws the node's own row when it has none and is due |
| `hide id` / `unhide id` | `detach` + `move` | a reversible per-node filter (treeview has no first-class hide) |
| `move id newparent` | `move id newparent end` | reparents (`""` makes it a root), then rebuilds; inside `batch` the rebuild waits for the batch's end, so several moves pay one |
| `batch script` | (none) | runs the script with the widget editable and the reader's view anchored once; a `move` inside it defers its rebuild to the batch's end |
| `column id -width N -minwidth M` | `column id -width N -minwidth M` | per-column width override and clamp |
| `rebuild` | (none) | re-render the whole tree from the durable store under the active sort |
| `reset` | `delete [children {}]` | empty the whole widget |
| `cursor` / `cursor_set id` | `focus` / `focus id` | the row the keyboard walks from; `cursor_set` scrolls it into view and fires `-cursorcb` |
| `cursor_move next\|prev\|first\|last` | (the class bindings) | step the cursor over the drawn rows |
| `cursor_open 1\|0` | `item id -open true/false` | expand or collapse the cursor's own node |
| `reveal id` | `see id` | opens every shut ancestor and scrolls the node's row into view |
| `expand_subtree id` | `item -open true` down the subtree | opens a node and everything under it, the view anchored once |

Every primitive owns its text-mark mutation and ends in `check_invariant`; a host never touches the underlying text widget.

`expand` calls the `populate` hook first, so it is safe on a lazily-built tree, and it degrades to recording the open flag on a node whose own row is not drawn. Opening one level everywhere is therefore a one-liner from outside, `batch` anchoring the reader's scroll position once for the whole sweep:

```tcl
$t batch { lmap id [$t roots] { $t expand $id } }
```

`expand_subtree id` opens every level under one node the same way, and `reveal id` opens the ancestors of one node and scrolls its row into view, the treeview `see`; a node that `hide` or `render_skip` keeps out has no row to reveal and the view stays put. `cursor_set` refuses a node with no row, so `reveal` is the step before it for a node shut away in a folder.

## THE CONTENT DOOR

Match snippets and badge windows are loose row content, not nodes. They go through a small door that appends inside a node's region and carries that node's end mark forward, along with every ancestor end coincident with it:

- `append_open id` → a temp mark at the node's append point
- `emit mark text tags` / `emit_window mark args` → insert text or an embedded window
- `append_close id mark` → advance the marks past what was emitted

## THE STREAMING CONTRACT

The widget's defining behaviour: content arriving while the user reads never moves what they are reading.

- A streamed mutation is bracketed with `anchor_save` / `anchor_restore`. A reader pinned at the top stays at the top; a reader inside the list keeps their line even when rows land above it.
- With `-autofollow 1` and the reader at the tail, the view latches to the tail and follows streamed appends (the `tail -f` / chat contract); the latch releases the moment they scroll away.
- `follow` jumps to the tail and re-latches.
- `<<AtBottom>>` and `<<LeftBottom>>` fire on the host frame when the view reaches or leaves the last line, so a host can show a "jump to latest" affordance the way chat clients do.

## HOOKS

Every hook has a working default: the base class renders each node's payload `label` (falling back to the node key) as a plain tree with no metadata columns.

Content / layout: `subject_label` (header over the subject column), `column_spec`, `render_subject`, `cell_values`, `cell_tag`, `sort_key`, `subject_sort_id` (the column id a click on the subject header sorts by; the default, `""`, leaves the subject unsortable), `default_sort_dir id` (the direction a freshly adopted sort starts in, `asc` or `desc`; the default is `desc` for every column, and a second click on the active column flips it), `apply_column_tabs` (default sets the tab stops widget-wide; override to configure row tags that carry their own `-tabs`), `relayout_content`.

Row lifecycle (per node kind): `start_gravity`, `row_tags`, `on_node_created` (register domain indices before the row renders), `on_row_rendered` (wire bindings, nested content, selection), `on_before_delete` (drop domain indices), `populate` (called at the top of `expand`; a lazy host enumerates and attaches the node's children here, a materialized tree keeps the no-op default).

Ordering and view membership: `kind_rank` (the integer rank a kind's run takes among siblings of mixed kinds, lowest first; the base class keeps each kind's nodes together, orders the runs by rank with ties in first-seen order, and hands each run to `sort_siblings` on its own, so that hook only ever sees one kind), `sort_siblings` (reorder a sibling set of one kind for display, keeping every node), `render_skip` (leave a node and its subtree out of the view while keeping it in the store; asked wherever a node is drawn with its content in place, so a skipped node stays out through `expand`, `unhide` and `rebuild` alike. `insert` does not ask it: what decides a skip, a node's children or aggregates, has not arrived when the node is born, so a new node draws on its place alone, and `expand` draws a node the skip kept out once it is due, no rebuild needed), `rebuild_restore` (re-pin the viewport to a captured top node), `arrival_in_order key dir` (whether a node streamed in now, last among its siblings, already sits where sort `key`, the active column id, in direction `dir`, `asc` or `desc`, puts it; `schedule_resort` does nothing while this says yes, and the default says no, so every arrival schedules the debounced resort until a subclass names the sort its arrivals keep. Override it when a column's order is the order nodes arrive in, an arrival-time column ascending, say: a stream under that sort then pays no rebuild per burst. A yes for a sort the arrivals do not keep leaves the list out of order until the next rebuild, so vouch only for what the source guarantees).

Aggregation: `aggregate_seed` (the value a subtree fold starts from) and `aggregate_add acc id` (that value with one node taken into it). The defaults count nodes.

## THE SUBCLASS SURFACE

A hook body works with its nodes through the store accessors, part of the subclassing contract: `node_exists id`, `node_get id` (the whole node dict), `node_field id field` / `node_set id field value` (one generic field), `node_payload id` (the opaque host dict) and `node_pget id key ?default?` / `node_pset id key value` (one payload key), `roots` (the ordered root ids), `ancestors id` (nearest first, up to the root) and `descendants id` (parents before children, siblings in store order, to any depth). Beside them sit the helpers a subclass reaches for while rendering and sorting: `colour role` (a `-colours` entry), `truncate_px text px font` (ellipsize to a pixel width), `all_rendered_nodes` (ids with a row in the view, document order), `render_row id ?before?` (draw one node's own row at its place, or before a drawn sibling's, the call a host's per-kind draw method makes), `set_sort id` (adopt a column as the active sort), `schedule_resort` (debounced re-sort after streamed edits, `-resortdelay`), and two sort helpers off the base class's own ordering path, for a host ordering its own key lists under the active sort: `sort_paths keys src` (each key's value read through `sort_key` from `src`, a key-to-payload dict; a key absent from it sorts as -1) and `sort_folders keys valmap ?mode?` (each key's value read from `valmap`, a key-to-value dict, compared `-real` by default or `-dictionary`; an absent key sorts as 0.0 or the empty string). The demos use exactly this surface and nothing deeper. A subclass that wants more than these and the hooks has found a gap in this surface, and the gap closes by naming the method here, where it joins the contract: what is not named is the base class's own and may change with any release.

`node_aggregate id ?shown?` is what a node adds up to: `aggregate_add` folded from `aggregate_seed` over the node and everything under it, parents before children. The host supplies the two hooks (a count of the leaves, a size summed from the payloads beneath a container) and the base class the walk, and only the walk: nothing is cached, so the answer after a move, a delete, a hide or a rewritten payload is the tree as it stands. With `shown` true a hidden node is left out with its whole subtree: the hidden flag is the one filter the store carries, so one fold answers both everything under a heading and what survives the hides. Open or shut and `render_skip` are draw-time decisions the fold does not consult: it reads the store, not the buffer, so a heading's figures hold while it is shut. At 0.7 µs a node with the default hooks (see PERFORMANCE), a heading's fold costs less than drawing the heading, which is why there is no cache to fall behind.

## OPTIONS

The base class takes its host-specific look and services as options, set through `configure` before the body is built, so its body holds no host references:

| Option | Default | Purpose |
|---|---|---|
| `-listfont` | `TkTextFont` | the row / list font |
| `-headfont` | `TkHeadingFont` | the column-heading font |
| `-colours` | a plain Tk palette | dict with keys `strip` (heading background), `muted` (heading ink), `ink` (active-column ink) |
| `-resortdelay` | `250` | ms a streamed resort debounces before one rebuild |
| `-autofollow` | `0` | keep the view latched to the tail while the reader is there |
| `-motioncb` | empty | a `<B1-Motion>` script the drag-to-move host wires in |
| `-cursorcb` | empty | fired `{new prev}` whenever the cursor moves, the only notice a host gets of one |

## THE AUDIT GATE

Set the `STREAMTREE_AUDIT` environment variable and every primitive checks the per-node mark contract after it runs: each drawn node's `[start,end]` region is well-formed, lies inside its parent's, and is ordered and disjoint from its siblings down the buffer, to any depth; a node with no row has no drawn descendant. The first violation latches `::STREAMTREE_AUDIT_TRIPPED` and writes an `INVARIANT @ <primitive>` line to stderr naming the operation that broke the contract. Production leaves the variable unset and pays nothing.

The check is not free: every audited primitive walks the whole store, the drawn regions and, under every undrawn node (a shut folder, a hidden one), all of its descendants, to confirm none has a row. A suite that keeps the gate on while it streams thousands of rows into shut folders pays that walk per insert, quadratic over the run; keep the gate on in the tests that drive the primitives, and off in the ones that only load a corpus.

## PERFORMANCE

Measured September 2026 on the 0.7.0 release (medians of 3, min-max in parentheses) on an Intel Core Ultra 7 258V under Xvfb software rendering, Tcl/Tk 9.0.3, by `bench-streamtree.tcl` beside the module. The streaming row is the median of three whole-bench runs pinned to the machine's performance cores; unpinned, a run that lands on an efficiency core carries a p95 half again as large, which measures the core it drew rather than the widget. The numbers are for the bare base class (one text string per row, no columns, no per-row bindings); a subclass with metadata columns and wired rows pays more per row.

| scenario | N | median (min-max) | per row | notes |
|---|---|---|---|---|
| bulk load, flat | 10,000 | 393 ms (377-442) | 39.3 µs | single flush for the whole batch |
| bulk load, flat | 50,000 | 3,717 ms (3,630-3,923) | 74.3 µs | single flush for the whole batch |
| bulk load, treed | 10,000 | 474 ms (455-485) | 47.4 µs | 100 expanded folders |
| bulk load, treed | 50,000 | 4,182 ms (4,136-4,383) | 83.6 µs | 100 expanded folders |
| streaming | 10k + 1,000 | 2,289 inserts/s | p95 738 µs | idle flush per insert; reader's line held |
| full rebuild | 10,000 | 807 ms (780-887) | 80.7 µs | the debounced resort's cost, and what a batch of moves pays once |
| memory, marginal row | 10k→50k | | 4.36 kB/row | includes the retained payload dict, per-row tag, two marks |
| subtree fold | 3,160 | 2 ms (2-3) | 0.7 µs | 160 folders three deep under 10 roots, default counting hooks, each root folded once |
| every heading folded | 160 folds | 5 ms (5-5) | | the same tree, each folder folded over its own subtree, what a redraw of every heading asks |

For calibration, ttk::treeview on the same machine bulk-loads 10k display-text-only rows in 18 ms (1.8 µs/row; 1.2 µs/row at 50k, a native C widget's floor) and holds 0.53 kB/row. It streams 2,983 inserts/s into a 10k flat list, but its scroll shifts on every insert; that repaint is baked into its number, where streamtree's number pays for the anchor work that prevents the shift. The workloads differ in what a row retains: streamtree keeps the payload dict, which doubles as the host's data model.

The base class renders every visible row into the text widget (no virtualization); collapsed subtrees stay unrendered, which is the intended posture for large trees. Practical ceiling: tens of thousands of rendered rows load in seconds and stream comfortably; memory is the binding constraint at roughly 4.4 kB per rendered row.

## LIMITS

To a screen reader the widget presents as one text area, not a tree of rows and columns; assistive-technology structure (row navigation, expansion state) is not exposed. Cell editing, checkbox columns, page-at-a-time keys, and type-ahead are not built in; a host can assemble them from embedded windows, row tags, and key bindings.

The list text does not carry the Text class bindtag, because an object list wants none of what that class does: its click gestures start a text selection and its motion keys scroll to an insert mark a list never maintains. The class's wheel scripts are kept. A host's own bindings go on the row tags, the widget, or the toplevel, all of which still run.

The arrows, Home and End are the module's own, walking the drawn rows through the cursor rather than an insert mark, and Right and Left open and shut the cursor's node so a keyboard can reach inside a folder. They act only while the list holds the focus, which the list takes for them. The cursor is a node id and no more: nothing is painted for it, so a host that wants a selection to follow the keyboard moves its own through `-cursorcb`.

## DECLARATIVE ATTRIBUTES

A consumer declares attributes on its rows: an id, a kind (bool or enum), a
label, an optional glyph, and whether a reader may filter on it. A glyphed
bool draws as a subject-prefix mark; a glyphless one as a check-mark column.
Filter controls build into a frame the host owns (a checkbutton per bool, a
stay-open combobox-style popdown per enum with select all and none, dismissed by a click outside, Escape, or the window moving); an enum filter is a
set of excluded values. Values reach the base class only through the attr_value
hook. The filter layer hides through a ledger of its own hides and composes
with the consumer's: a node shows only when nobody hides it. The module
header carries the full contract.

## OPEN QUESTION

Filter kinds past bool and enum. A consumer will one day want a scalar
threshold (a numeric column above some value) or a free-text match as a
filter. What the control looks like, how a threshold is typed, and whether
text matching belongs in a tree widget at all are undecided; the kind field
in the declaration is the extension point when the design round happens.

## REQUIREMENTS

Tcl 9 and Tk. The sibling of [streamdoc](streamdoc.md): a tree of rows here, a document of regions there, the same architecture.

## KEYWORDS

treeview, text widget, tree, columns, sort, streaming, virtual list
