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

streamtree renders a tree of abstract nodes into a single `text` widget: nodes nested to any depth, each rendered as one row, with a right-pinned metadata strip whose sortable, resizable columns line up across every row. A widget too narrow for its strip drops columns from the right until the rest leave the subject its floor (80 px), so the leading columns, the ones a host names first, are the ones that survive a narrow pane; they return as the widget widens. It reuses treeview's *vocabulary* so the API reads as familiar. Each node carries the position marks and tag that locate it in the widget plus an opaque domain payload; the subclass supplies content and ordering through hooks (Template Method), and the base class never looks inside a payload.

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
| `move id newparent` | `move id newparent end` | reparents (`""` makes it a root) last among its new siblings, then rebuilds; inside a batch the rebuild waits for the batch's end, so several moves pay one. There is no index argument: where the node lands is the sort's to say at the rebuild |
| `batch script` | (none) | runs the script with the widget editable and the reader's view anchored once; a `move` inside it defers its rebuild to the batch's end |
| `begin_batch` / `end_batch` | (none) | the same bracket as two calls, for a host whose edits arrive streamed: open it in one callback, close it in another. It counts depth, so a bracket inside an open one (a `batch` included) is a no-op and the outermost `end_batch` restores the view and the widget state and runs the deferred rebuild; `batch_depth` says how many are open |
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

- A streamed mutation is bracketed with `anchor_save` / `anchor_restore`. A reader pinned at the top stays at the top; a reader inside the list keeps their line even when rows land above it. The pair counts its depth: a bracket opened while one is open, a primitive's own `batch` inside a host's bracket say, is a no-op, and only the outermost pair saves and restores.
- With `-autofollow 1` and the reader at the tail, the view latches to the tail and follows streamed appends (the `tail -f` / chat contract); the latch releases the moment they scroll away.
- `follow` jumps to the tail and re-latches.
- `<<AtBottom>>` and `<<LeftBottom>>` fire on the host frame when the view reaches or leaves the last line, so a host can show a "jump to latest" affordance the way chat clients do.

## HOOKS

Every hook has a working default: the base class renders each node's payload `label` (falling back to the node key) as a plain tree with no metadata columns.

Content / layout: `subject_label` (header over the subject column), `column_spec`, `render_subject`, `cell_values`, `cell_tag`, `sort_key`, `subject_sort_id` (the column id a click on the subject header sorts by; the default, `""`, leaves the subject unsortable), `default_sort_dir id` (the direction a freshly adopted sort starts in, `asc` or `desc`; the default is `desc` for every column, and a second click on the active column flips it), `apply_column_tabs tabs` (handed the stops of the columns the current width lays, one per laid column; the default sets them widget-wide, a host whose row tags carry their own `-tabs` configures those tags instead), `relayout_content`. A `cell_values` pair for a column the width has dropped is left out of the row with its stop, so a host lays every column it declares and lets the width decide.

Row lifecycle (per node kind): `start_gravity`, `row_tags`, `on_node_created` (register domain indices before the row renders), `on_row_rendered` (wire bindings, nested content, selection), `on_before_delete` (drop domain indices), `populate` (called at the top of `expand`; a lazy host enumerates and attaches the node's children here, a materialized tree keeps the no-op default).

Ordering and view membership: `kind_rank` (the integer rank a kind's run takes among siblings of mixed kinds, lowest first; the base class keeps each kind's nodes together, orders the runs by rank with ties in first-seen order, and hands each run to `sort_siblings` on its own, so that hook only ever sees one kind), `sort_siblings` (reorder a sibling set of one kind for display, keeping every node), `render_skip` (leave a node and its subtree out of the view while keeping it in the store; asked wherever a node is drawn with its content in place, so a skipped node stays out through `expand`, `unhide` and `rebuild` alike. `insert` does not ask it: what decides a skip, a node's children or aggregates, has not arrived when the node is born, so a new node draws on its place alone, and `expand` draws a node the skip kept out once it is due, no rebuild needed), `rebuild_restore` (re-pin the viewport to a captured top node), `arrival_in_order key dir` (whether a node streamed in now, last among its siblings, already sits where sort `key`, the active column id, in direction `dir`, `asc` or `desc`, puts it; `schedule_resort` does nothing while this says yes, and the default says no, so every arrival schedules the debounced resort until a subclass names the sort its arrivals keep. Override it when a column's order is the order nodes arrive in, an arrival-time column ascending, say: a stream under that sort then pays no rebuild per burst. A yes for a sort the arrivals do not keep leaves the list out of order until the next rebuild, so vouch only for what the source guarantees).

Aggregation: `aggregate_seed` (the value a subtree fold starts from) and `aggregate_add acc id` (that value with one node taken into it). The defaults count nodes.

## THE SUBCLASS SURFACE

A hook body works with its nodes through the store accessors, part of the subclassing contract: `node_exists id`, `node_get id` (the whole node dict), `node_field id field` / `node_set id field value` (one generic field), `node_payload id` (the opaque host dict) and `node_pget id key ?default?` / `node_pset id key value` (one payload key), `roots` (the ordered root ids), `ancestors id` (nearest first, up to the root) and `descendants id` (parents before children, siblings in store order, to any depth). Beside them sit the helpers a subclass reaches for while rendering and sorting: `colour role` (a `-colours` entry), `truncate_px text px font` (ellipsize to a pixel width: the text when it fits, else as much as fits with an ellipsis, else the empty string when even the ellipsis would overrun, so what comes back never exceeds `px`), `laid_columns` (the columns the current width lays, the leading run of the declared strip) and `column_at x` (the laid column under a header x, or `""` in a gap or the subject zone), `all_rendered_nodes` (ids with a row in the view, document order), `render_row id ?before?` (draw one node's own row at its place, or before a drawn sibling's, the call a host's per-kind draw method makes), `sort` (the active sort as `{key dir}`, what a `sort_siblings` body orders by), `set_sort id` (adopt a column as the active sort), `schedule_resort` (debounced re-sort after streamed edits, `-resortdelay`), `batch_depth` (how many batch brackets are open, for a host deferring per-row work to the outermost close), and two sort helpers off the base class's own ordering path, for a host ordering its own key lists under the active sort: `sort_by_payload keys payloads` (each key's value read through `sort_key` from `payloads`, a key-to-payload dict; a key absent from it sorts as -1) and `sort_by_value keys valmap ?mode?` (each key's value read from `valmap`, a key-to-value dict, compared `-real` by default or `-dictionary`; an absent key sorts as 0.0 or the empty string). The demos use exactly this surface and nothing deeper. A subclass that wants more than these and the hooks has found a gap in this surface, and the gap closes by naming the method here, where it joins the contract: what is not named is the base class's own and may change with any release.

`node_aggregate id ?shown?` is what a node adds up to: `aggregate_add` folded from `aggregate_seed` over the node and everything under it, parents before children. The host supplies the two hooks (a count of the leaves, a size summed from the payloads beneath a container) and the base class the walk, and only the walk: nothing is kept past one row build, so the answer after a move, a delete, a hide or a rewritten payload is the tree as it stands. Within one row build (`render_subject`, `cell_values` and `cell_tag` for the node whose row is being laid) the node's own fold is taken on the first ask and handed to every later one, so a heading whose three hooks each read it pays one walk per draw rather than three; the transient is dropped when the build ends, and a hook asked outside a build folds for itself. With `shown` true a hidden node is left out with its whole subtree: the hidden flag is the one filter the store carries, so one fold answers both everything under a heading and what survives the hides. Open or shut and `render_skip` are draw-time decisions the fold does not consult: it reads the store, not the buffer, so a heading's figures hold while it is shut. At under a microsecond a node with the default hooks and a few with a host's (see PERFORMANCE), a heading's fold costs less than drawing the heading, which is why there is no cache to fall behind.

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

Measured September 2026 on the 0.8.0 release (medians of 3, min-max in parentheses) on an Intel Core Ultra 7 258V under Xvfb software rendering, Tcl/Tk 9.0.3, by `bench-streamtree.tcl`, which sits beside the module's source in its home repository and does not travel with a vendored copy. The streaming row is the median of three whole-bench runs pinned to the machine's performance cores; unpinned, a run that lands on an efficiency core carries a p95 more than twice as large, which measures the core it drew rather than the widget. Compare rows within this table, not against the 0.7.0 table: on the day of this measurement the same machine ran the 0.7.0 release's flat 10k load in 472 ms against its published 393, and a side-by-side of the two releases put 0.8.0's row build 2-4% dearer (the once-per-build fold transient), not the 40% the two tables show apart. The numbers are for the bare base class (one text string per row, no columns, no per-row bindings) except the two real-hooks rows; a subclass with metadata columns and wired rows pays more per row.

| scenario | N | median (min-max) | per row | notes |
|---|---|---|---|---|
| bulk load, flat | 10,000 | 562 ms (551-621) | 56.2 µs | single flush for the whole batch |
| bulk load, flat | 50,000 | 4,705 ms (4,685-4,805) | 94.1 µs | single flush for the whole batch |
| bulk load, treed | 10,000 | 597 ms (589-622) | 59.7 µs | 100 expanded folders |
| bulk load, treed | 50,000 | 5,586 ms (5,259-5,729) | 111.7 µs | 100 expanded folders |
| streaming | 10k + 1,000 | 1,691 inserts/s | p95 982 µs | idle flush per insert; reader's line held |
| full rebuild | 10,000 | 1,002 ms (985-1,028) | 100.2 µs | the debounced resort's cost, and what a batch of moves pays once |
| memory, marginal row | 10k→50k | | 4.36 kB/row | includes the retained payload dict, per-row tag, two marks |
| subtree fold | 3,160 | 3 ms (3-3) | 1.1 µs | 160 folders three deep under 10 roots, default counting hooks, each root folded once |
| every heading folded | 160 folds | 7 ms (7-7) | | the same tree, each folder folded over its own subtree, what a redraw of every heading asks |
| subtree fold, real hooks | 3,160 | 12 ms (11-13) | 3.9 µs | the same tree, the fold summing three payload fields into a dict, each root folded once |
| every heading redrawn, real hooks | 160 headings | 274 ms (274-279) | 1.7 ms | `item` on each drawn heading, its subject, cell and cell tag each reading the shown fold: 9,430 `aggregate_add` calls, one walk per heading. The 0.7.0 release, three walks per heading, made 28,290 calls in 328 ms on the same day |

The real-hooks rows are what a consumer feels: a heading pass is dominated by the text widget's own delete, insert and tag work per line, and the fold is the part a host's hooks scale. A host whose root heading folds its whole corpus on every flush pays that fold once per redraw now, where 0.7.0 paid it three times.

For calibration, ttk::treeview on the same machine bulk-loads 10k display-text-only rows in 18 ms (1.8 µs/row; 1.2 µs/row at 50k, a native C widget's floor) and holds 0.53 kB/row, measured with the 0.7.0 table. It streams 2,983 inserts/s into a 10k flat list, but its scroll shifts on every insert; that repaint is baked into its number, where streamtree's number pays for the anchor work that prevents the shift. The workloads differ in what a row retains: streamtree keeps the payload dict, which doubles as the host's data model.

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

## CHANGES

Newest release first, one entry per release, each saying what a host gains and
what an existing subclass has to answer differently when it takes that release.
The record starts at 0.4.0; anything earlier is in the commit log at the
module's home repository alone.

**0.8.0.** The release the 0.7.0 review deferred to: nine changes to the
surface a subclass writes against, and one to the bracket every mutation
runs under, made in place because the module has one consumer and no
alias would serve anyone. A subclass answers for: `sort_paths` and
`sort_folders` are `sort_by_payload` and `sort_by_value`, named for what they
order, with the same arguments; `FolderLabelMax` is `LabelMax`, the budget
before the first tab stop for a label laying no cell of its own; `move` takes
no third argument (the trailing index it accepted was dropped unread, and
where a node lands is the sort's to say); `truncate_px` returns the empty
string when even the ellipsis would overrun the budget, where it returned the
ellipsis alone, so a host measures nothing before calling it; and a strip too
wide for the widget drops columns from the right until the rest leave the
subject its floor, where it laid every stop one pixel past the last at the
left edge, so a host's `apply_column_tabs` may be handed fewer stops than it
declared columns and a `cell_values` pair for a dropped column is left out of
the row. A host gains: `sort`, the active sort as `{key dir}`, so a
`sort_siblings` body reads no base-class variable; `laid_columns` and
`column_at x`, the strip as the width lays it; `begin_batch` and `end_batch`,
the batch bracket as two calls for a host whose edits arrive streamed, with
`batch_depth` beside them and `batch` rewritten over the pair; and one fold per
row build, `node_aggregate` for the node whose row is being laid answering
from a transient the build holds and drops, so a heading whose subject, cells
and cell tags each read its fold pays one walk rather than three (the
real-hooks rows in PERFORMANCE). The anchor pair counts its depth, so a bracket
opened inside an open one, a `batch` inside a `batch` or a primitive's own
inside a host's `anchor_save`, is a no-op that leaves the outer's record
standing; an unguarded inner restore used to unset the shared mark and the
outer's restore failed in silence. `bench-streamtree.tcl` times a heading pass
with real hooks, so the PERFORMANCE table carries the number a consumer feels.

**0.7.0.** `arrival_in_order key dir` is now the only answer to whether a node
streamed in this moment, last among its siblings, already sits where the active
sort puts it. The base class used to answer that itself, for a `date` column
descending it had no business knowing about; that assumption is gone and the
hook's default says no, so every arrival schedules the debounced resort until a
subclass names the sort its arrivals keep. A host with a date column, the one
the old assumption served, now pays a rebuild per burst until it overrides the
hook and vouches for that key and direction; a host under any other sort pays
what it always paid. Vouch only for what the source guarantees: a yes for a
sort the arrivals do not keep leaves the list out of order until the next
rebuild. Also in this release: `move id ""` makes a node a root, last among
them, where it used to error on the children of a parent that is no node;
several `move`s inside one `batch` pay one rebuild at the batch's end rather
than one each, and a moved node has no row until that end; `insert -pos {before
id}` draws the row before that sibling's own row instead of at the parent's
append point, so the view no longer disagrees with the store until a rebuild;
and `move` ends in `check_invariant` under its own name, as every other
primitive does.

**0.6.0.** `node_aggregate id ?shown?` folds `aggregate_add` from
`aggregate_seed` over a node and everything under it, parents before children,
so a heading can carry the totals of its whole subtree and get both figures,
everything and only what the hides leave, from one walk. Nothing is cached, so
a move, a delete, a hide or a rewritten payload is in the next answer. The two
hooks default to counting nodes, so a subclass that wants none of this changes
nothing.

**0.5.2.** Three fixes a nested host meets: `unhide` now seats the node last
among its siblings in the store, matching where it draws the row, so a host
reading the store back after an unhide finds it there and a later rebuild does
not jump the row; `render_row` makes the widget editable itself and restores,
so a subclass helper that calls it outside a `batch` no longer loses its line
in silence and leaves the node's marks inverted; and the audit gate judges
sibling disjointness in buffer order rather than store order, so a host that
draws rows out of store order and lets the debounced resort seat them stops
tripping the gate on healthy work. A genuine overlap still trips it.

**0.5.1.** `insert` no longer asks `render_skip`. A skip derived from a node's
content cannot be answered when the node is born, so `insert` draws on the
structural half alone (not hidden, under a parent whose row is drawn and open)
and the skip is asked only where a node is drawn with its content in place:
`expand`, `unhide` and `rebuild`. A host whose skip reads its children, an
empty folder's above all, gets its nodes drawn at birth again, which 0.5.0 had
taken away. `expand` is the way back for a node the skip kept out: it draws the
row when it is due, at the parent's append point, and seats the node last among
its siblings for the resort to place, as any streamed row is.

**0.5.0.** The tree is as deep as the consumer nests it. `all_rendered_nodes`,
the cursor's roster, and the audit gate walk root to leaf, so a row at depth
four is reachable from the keyboard and a child's region sliding out of its
parent's now trips the gate. One predicate decides whether a row is due, and
every drawing path asks it, so a skipped node stays out whichever primitive
reaches it and a hidden root stays hidden through a rebuild. Two consequences
for an existing subclass: `render_skip` is now asked on every draw rather than
once per rebuild, so a skip that is expensive is paid per insert (0.5.1 takes
`insert` back off that path); and `expand` draws a child's open subtree rather
than one level, so a subclass overriding `render_subtree` to stop at a kind
finds `expand` and `unhide` going through that override too. New to the
subclass surface: `ancestors` and `descendants`, the `kind_rank` hook (which
orders the runs of a mixed-kind sibling set and hands each run to
`sort_siblings` on its own, so that hook now only ever sees one kind), `reveal`
and `expand_subtree`.

**0.4.0.** The keyboard walks the rows. The cursor is a node id and no more:
`cursor`, `cursor_set`, `cursor_move` and `cursor_open` drive it, the arrows,
Home and End step it over the drawn rows, and Right and Left open and shut the
cursor's own node. Nothing is painted for it; a host that wants a selection to
follow the keyboard moves its own through the new `-cursorcb`, fired
`{new prev}` on every move. The list takes the focus for these keys, and the
Text class bindtag stays off, so a toplevel's own accelerators still run.

## REQUIREMENTS

Tcl 9 and Tk. The sibling of [streamdoc](streamdoc.md): a tree of rows here, a document of regions there, the same architecture.

## KEYWORDS

treeview, text widget, tree, columns, sort, streaming, virtual list
