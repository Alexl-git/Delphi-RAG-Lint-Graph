# drag-lint / graph viewer - test checklist (2026-06-03)

Three groups. **A and B are standalone and ready NOW (no IDE).**
**C needs the plugin BPL installed in RAD Studio** (optional / your call).

--------------------------------------------------------------------------
## A. GRAPH VIEWER  -  standalone, ready now
Start it (no IDE):

    C:\Projects\Delphi-RAG-Lint-Graph\bin\Win32\drag_lint_graph.exe --db C:\Projects\DB\ORM3\drag-lint.sqlite

(To also see library types, add a second db:
  ... --db C:\Projects\Delphi-RAG-lint\third_party\dll-win32\drag-lint-library.sqlite )

[ ] A1. Window opens within a couple seconds, responsive (NO hang) on the 44k-symbol index.
[ ] A2. On load you see a handful of UNIT boxes (collapsed), not a hairball.
[ ] A3. LEFT-click a unit box -> DRILLS IN: the view shows ONLY that unit's
        classes/interfaces/records (zoomed to fit). A BREADCRUMB bar appears on
        top: "Project > <Unit>".
[ ] A3b. Click a class -> opens its source (it's already a UML box).  Click the
         "Project" crumb (or an earlier crumb) -> jumps back that many levels.
[ ] A4. A class/interface/record draws as a UML BOX: title bar (<<interface>> /
        <<record>> stereotype) over a member list.
[ ] A5. Each member row has a visibility glyph:  + public   - private   # protected   ~ published
[ ] A6. Member rows show the TYPE:  e.g.  "- FList: TList<TFoo>",  "+ GetX: Boolean"
        (functions show return type; procedures have none).
[ ] A7. A box with many members shows "v N more below"; MOUSE-WHEEL over the box
        scrolls the list (^ N above / v N below). (Wheel over empty canvas = zoom.)
[ ] A8. LEFT-click a member ROW -> opens that member's source
        (standalone: opens the .pas in your default editor; in the IDE: jumps - see C1).
[ ] A9. PAN = hold the RIGHT mouse button and drag. The cursor shows the move (4-arrow)
        icon ONLY while right is held. Releasing returns to a normal pointer.
[ ] A10. There is NO flicker and NO "stuck in move mode" when you just move the mouse.
[ ] A11. LEFT-drag a box/circle to move it aside; it STAYS where you drop it.
[ ] A12. LEFT-click empty canvas -> clears the selection.
[ ] A13. Select a node, then LEFT-click a LINK line attached to it -> selects the
         node at the OTHER end (walk along the link). Click its next link -> hop again.
[ ] A14. interface <-> class links draw DASHED CYAN (who-implements-what).
[ ] A14b. A class/record/interface declared in a unit's IMPLEMENTATION section
          shows "[impl-only]" in its box title; hover says "(implementation-only
          - not usable from another unit)" vs "(interface section)".
[ ] A15. RIGHT-click a node (no drag) -> context menu:
         Open Source (Definition) / Go to Interface / Where Used (focus) / Center Here.
[ ] A16. "Go to Interface" selects a connected interface (enabled only when one exists).
[ ] A17. HOVER: rest the mouse on a member (don't move) ~0.5s -> a tooltip pops with
         Kind: QualifiedName, the type, and any doc summary. Moving the mouse dismisses it.
[ ] A18. STATUS BAR (bottom) shows where you are on each selection:
         e.g. "Method: uPLANLIST.TmcPLANLIST.Create  (uPLANLIST.pas:88)".
[ ] A19. ZOOM: the slider + "Fit" button (top-right) zoom / reset the view.
[ ] A20. Double-click a node -> drills in (navigate into it).
[ ] A21. NAV HISTORY: top-right has "<" (Back) and ">" (Forward) buttons left of
         "Fit". Both start DISABLED (greyed). Hover shows "Back -- previous graph
         view" / "Forward -- next graph view".
[ ] A22. Search/select several different symbols in turn (left panel tree, or the
         search box) -> "<" Back becomes enabled after the 2nd. Click "<" -> the
         graph re-centers on the PREVIOUS view; ">" Forward becomes enabled.
[ ] A23. Click ">" Forward -> returns to the later view. At the ends of the
         history the respective button greys out again (no wrap).
[ ] A24. After going Back a few steps, navigate somewhere NEW -> the forward tail
         is dropped (">" greys); the new view is appended. History caps at 100
         (oldest views fall off; no unbounded growth).

--------------------------------------------------------------------------
## B. COMMAND LINE  -  standalone, ready now
Run from a terminal. exe: C:\Projects\Delphi-RAG-lint\third_party\dll\drag-lint.exe

[ ] B1. "Where is this defined / what unit do I add to uses?"
        drag-lint resolve-uses --name <SomeConstOrType> --db C:\Projects\DB\ORM3\drag-lint.sqlite
        -> lists the defining unit(s), ranked, with a "Suggestion: add X to uses".
        Units where the symbol is implementation-only show
        "<impl-only: NOT usable via uses>" and get no suggestion.
[ ] B2. Find a symbol (AST-exact, no string-literal noise):
        drag-lint query --name <Symbol> --db C:\Projects\DB\ORM3\drag-lint.sqlite
        (add --json to see signature + modifiers/visibility)
[ ] B3. Find references / callers:
        drag-lint query find-callers --name <Method> --db C:\Projects\DB\ORM3\drag-lint.sqlite
[ ] B4. Syntax errors (Error-Insight style, no compiler):
        drag-lint check-ast <some.pas>
        -> reports "(line,col): error syntax-error" for each ERROR/MISSING spot.
[ ] B5. "Can I call this from another unit?" (interface vs implementation):
        drag-lint query --name <Symbol> --db C:\Projects\DB\ORM3\drag-lint.sqlite
        -> implementation-only symbols show "[impl-only]"; --json adds
        "section" + "usable_from_other_units". Method rows show ": <signature>".

--------------------------------------------------------------------------
## C. IDE PLUGIN  -  needs the BPL installed in RAD Studio
NOT installed yet. To try these: RAD Studio -> Component -> Install Packages ->
add C:\Projects\Delphi-RAG-lint\third_party\dll-win32\dclDragLintWizard.bpl
(Heads-up: this plugin had install/unload AVs earlier in development; it builds
clean now but in-IDE behaviour is unverified - install at your discretion.)

[ ] C1. Live jump-to-source: with the IDE open and the plugin loaded, run the graph
        viewer (section A) and LEFT-click a member -> the IDE opens that file at the
        exact line/column (named pipe \\.\pipe\drag-lint-open-source).
[ ] C2. Syntax-error markers appear in the editor for files with errors (B4 detection).
[ ] C3. Tools -> drag-lint menu: Hover at Cursor, Symbol Search, etc.
[ ] C4. Tools -> drag-lint -> "Dockable Panel (test)" -> a panel opens that you can
        dock/park at the bottom of the IDE like GExperts Grep (placeholder content).

--------------------------------------------------------------------------
## D. AUTOMATION  -  already live
[ ] D1. A test email was already delivered to alexanderliberov@gmail.com.
[ ] D2. The "DragLint Daily Report" Windows task runs daily at 4:00 PM and emails a
        report: drag-lint-vs-Grep savings + GitHub activity across all 6 repos
        (downloads/stars/issues/traffic + day-over-day deltas). Next run: today 4 PM.

--------------------------------------------------------------------------
NOTE: all code is committed LOCALLY and NOT pushed to GitHub (per your hold).
