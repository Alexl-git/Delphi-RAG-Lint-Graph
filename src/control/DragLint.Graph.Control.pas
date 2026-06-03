unit DragLint.Graph.Control;

(* TDragLintGraphControl: passive VCL View bound to IGraphViewModel.
   Renders VM.Projection through DragLint.Graph.Style. Routes mouse/keyboard
   input to VM commands. Repaints on VM.OnChanged; relayouts on
   VM.OnStoreChanged (full store re-layout, simplification: visible-only
   relayout deferred to a later LOD phase).

   Coordinate model (unchanged from Phase 0):
     Logical "world" coordinates live in TGraphNode.X/.Y as Doubles centred
     around (0,0). On-screen pixel position:
       sx = (X - FOffsetX) * FZoom + ClientWidth  / 2
       sy = (Y - FOffsetY) * FZoom + ClientHeight / 2
     Pan = mutating FOffsetX/Y. Zoom = mutating FZoom around mouse anchor.

   Layout (finding F8 fix):
     * The force-directed layout runs over only the *visible* projection
       nodes (collapse-resolved), not the whole indexed tree.  On Bind/
       StoreChanged the store opens collapsed to the top level, so the first
       layout is a handful of unit bubbles.  Expanding a node seeds its newly
       revealed children (near the parent) and re-settles just the visible set
       -- O(V^2) in the visible count, never O(N^2) over the full store.
       A node keeps its world position when collapsed and revealed again
       (placement tracked in FPlaced by node index).
     * Cross-DB edges are not drawn within a single-store graph; external-
       node click raises OnCrossDbJump for the host.
     * Diamond/hexagon/cylinder/tag/triangle shapes fall back to a labelled
       rectangle for P4; ellipse/box/roundbox are distinct.

   Hover-highlight intentionally removed (bug F1):
     MouseMove no longer hit-tests nodes and does NOT call Invalidate unless
     a pan drag is in progress.  This eliminates the continuous repaint storm
     over large graphs (~16k nodes).  Selection highlight (blue border) still
     works: clicking calls FVM.SelectNode then Invalidate.

   Projection cache:
     FProjection/FProjValid cache the last TGraphProjection.  The cache is
     invalidated (FProjValid := False) only on VM state changes (Changed,
     StoreChanged, Bind).  Pan/zoom/scroll call Invalidate without
     invalidating the cache, so Paint reuses the cached projection for those
     fast redraws -- no O(nodes+edges) rebuild per pan step.
*)

interface

uses
  System.SysUtils, System.Classes, System.Types, System.Math,
  System.UITypes, System.Generics.Collections,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.ExtCtrls, Vcl.Menus,
  Winapi.Windows, Winapi.Messages,
  DragLint.Graph.Types,
  DragLint.Graph.Source,
  DragLint.Graph.ViewModel,
  DragLint.Graph.Style,
  DragLint.Graph.Layout;

type
  TGraphNodeEventArgs = record
    Node:   PGraphNode;
    Ctrl:   Boolean;
    Shift:  Boolean;
    Alt:    Boolean;
  end;

  TGraphNodeEvent      = procedure(Sender: TObject;
                                   const A: TGraphNodeEventArgs) of object;
  TGraphHoverEvent     = procedure(Sender: TObject;
                                   ANode: PGraphNode) of object;
  TGraphIdEvent        = procedure(Sender: TObject;
                                   const AId: string) of object;
  TGraphNameEvent      = procedure(Sender: TObject;
                                   const AName: string) of object;
  { Open-source carries the clicked node itself so the host can read its exact
    FilePath/Line/Col/DbId -- no qualified-name re-lookup, so overloads resolve
    to the precise row the user clicked (contract Q1). }
  TGraphOpenSourceEvent = procedure(Sender: TObject;
                                    ANode: PGraphNode) of object;

  { Geometry of a drawn UML class-box, captured each paint so a click can be
    mapped to the title (-> the type) or a member row (-> that member). }
  TUmlBoxHit = record
    NodeIdx: Integer;        { the class/interface/record node }
    Box:     TRect;          { full box bounds (screen px) }
    RowTop:  Integer;        { Y of the first member row }
    RowH:    Integer;        { row height }
    Members: TArray<Integer>;{ child node indices, in row order (capped) }
  end;

  TDragLintGraphControl = class(TCustomControl)
  strict private
    FVM:     IGraphViewModel;
    FLayout: TGraphLayout;

    { View transform }
    FZoom:    Double;
    FOffsetX: Double;
    FOffsetY: Double;

    { Mouse interaction state }
    FDragging:    Boolean;       { panning the canvas }
    FDragStartPt: TPoint;
    FDragStartOX: Double;
    FDragStartOY: Double;

    { Node drag-or-click state: a left-press on a node defers its click action
      to MouseUp, so a drag (move the node) and a click (select/open) can be
      told apart.  A dragged node is pinned (Fixed) so relayout leaves it put. }
    FDragNodeIdx: Integer;       { node being pressed/dragged, -1 if none }
    FNodeMoved:   Boolean;       { moved past the click threshold }
    FGrabDX:      Double;        { node.X - worldUnderCursor.X at press }
    FGrabDY:      Double;
    FDownPt:      TPoint;
    FDownShift:   TShiftState;
    FRightMoved:  Boolean;       { canvas pan moved past the click threshold }
    FPanButton:   TMouseButton;  { which button started the active canvas pan }

    { Roam + dwell hover: when the button is up, moving freely sets a hand
      cursor over nodes; pausing pops a hint (kind/name/type/doc).  No repaint
      on move (that was bug F1) -- the hint is a separate window. }
    FHoverTimer: TTimer;
    FHoverPt:    TPoint;
    FHintWin:    THintWindow;

    { Projection cache -- rebuilt only when VM state changes }
    FProjection: TGraphProjection;
    FProjValid:  Boolean;

    { Layout placement tracking (finding F8): node indices into FVM.Data that
      already have a world position.  Lets a revealed node keep its place and
      lets newly revealed children seed near their parent.  Cleared when the
      store reloads (node indices are only stable within one store). }
    FPlaced: TDictionary<Integer, Boolean>;

    { UML class-box geometry from the last paint, for box/row hit-testing. }
    FUmlBoxes: TArray<TUmlBoxHit>;

    { Per-box member-list scroll offset (NodeIdx -> first visible member row),
      for wheel-scrolling a box whose member list is longer than the cap. }
    FBoxScroll: TDictionary<Integer, Integer>;

    { Right-click context menu + the node it was raised on. }
    FPopup:          TPopupMenu;
    FMiOpen:         TMenuItem;
    FMiWhereUsed:    TMenuItem;
    FMiGotoIntf:     TMenuItem;
    FMiCenter:       TMenuItem;
    FMiSep:          TMenuItem;
    FMiFit:          TMenuItem;
    FMiBack:         TMenuItem;
    FContextNodeIdx: Integer;

    { Optional progressive relayout timer (Phase-0 proven) }
    FAnimTimer:   TTimer;

    { Published settings }
    FShowLegend: Boolean;
    FExpandOnSingleClick: Boolean;

    { True while a focus-neighborhood is active (Shift+click / 'F').  Tracked
      locally so Esc can clear focus first, then fall back to resetting the
      top-level cap -- without widening IGraphViewModel. }
    FFocusActive: Boolean;

    FOnNodeClick:       TGraphNodeEvent;
    FOnNodeHover:       TGraphHoverEvent;
    FOnSelectionChange: TNotifyEvent;
    FOnOpenSource:      TGraphOpenSourceEvent;
    FOnCrossDbJump:     TGraphNameEvent;
    FOnViewChanged:     TNotifyEvent;
    FOnZoomChanged:     TNotifyEvent;

    procedure AnimTick(Sender: TObject);

    { VM event callbacks }
    procedure HandleVMChanged(Sender: TObject);
    procedure HandleVMStoreChanged(Sender: TObject);

    { Layout / view helpers }
    procedure Relayout;
    { Seed any newly revealed visible nodes and settle the visible set.
      AForceAll re-runs the full settle (Bind/StoreChanged); otherwise it is a
      cheap incremental pass that only does work when new nodes appeared. }
    procedure EnsureLayout(AForceAll: Boolean);

    function  WorldToScreen(WX, WY: Double): TPoint;
    function  ScreenToWorld(SX, SY: Integer): TPointF;
    function  HitTestProjNode(SX, SY: Integer;
                              const AProj: TGraphProjection): Integer;
    function  HitTestProjEdge(SX, SY: Integer;
                              const AProj: TGraphProjection): Integer;
    { If (SX,SY) falls in a drawn UML class-box, act on it (member row -> open
      that member; title -> select/open the type) and return True. }
    function  HandleUmlBoxClick(SX, SY: Integer): Boolean;
    { Resolve the most specific node under (SX,SY): a UML member row -> that
      member; a UML box title -> the type; otherwise the circle node. -1 if none. }
    function  NodeIdxAt(SX, SY: Integer): Integer;
    { The draggable node under (SX,SY): a UML box -> its type node (move the
      whole box), else the circle node. -1 if none. }
    function  MovableNodeAt(SX, SY: Integer): Integer;
    { Perform the left-click action at (SX,SY) -- box row/title or circle node.
      Called from MouseUp when the press did not turn into a drag. }
    procedure DoLeftClickAt(SX, SY: Integer; AShift: TShiftState);
    { Dwell-hover hint. }
    procedure HoverTick(Sender: TObject);
    procedure ShowHoverHint(const APt: TPoint; const AText: string);
    procedure HideHoverHint;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
    { Right-click context menu. }
    procedure ShowContextMenu(SX, SY: Integer);
    procedure CtxOpenSource(Sender: TObject);
    procedure CtxWhereUsed(Sender: TObject);
    procedure CtxGotoInterface(Sender: TObject);
    procedure CtxCenter(Sender: TObject);
    procedure CtxFit(Sender: TObject);
    procedure CtxBack(Sender: TObject);
    { Go up one level: drill-up if drilled, else un-show-all, else VM Back.
      Wired to Backspace, the mouse back thumb button, and the canvas menu. }
    procedure NavigateBack;
    { After the force pass, gather still-isolated visible nodes (no visible
      relation edge) and pack them into a tidy grid beside the connected
      cluster, so they do not fly to the edges (keeps Fit usable + labels
      reachable). }
    procedure PackIsolatedNodes(const AVisIdx, AESrc, AEDst: TArray<Integer>);
    procedure WMXButtonUp(var Msg: TMessage); message WM_XBUTTONUP;

    { Returns the cached projection, rebuilding it if necessary. }
    function  CurrentProjection: TGraphProjection;

    procedure DrawEdges(const AProj: TGraphProjection);
    procedure DrawNodes(const AProj: TGraphProjection);
    { UML class-box for a class/interface/record node: a titled frame with its
      members listed inside (visibility glyph + name), drawn at ACenter.
      Members come straight from TGraphData.ChildrenOf, so they need not be
      separate projection nodes.  ASelected highlights the frame border. }
    procedure DrawUmlTypeBox(ANode: PGraphNode; ANodeIdx: Integer;
      const ACenter: TPoint; ASelected: Boolean);
    procedure DrawLegend(const AProj: TGraphProjection);
    procedure DrawArrowHead(PA, PB: TPoint);

  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    function  DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure DblClick; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Bind a ViewModel. Subscribes to its events and triggers relayout. }
    procedure Bind(const AVM: IGraphViewModel);

    procedure FitToWindow;

    { SetZoomLevel: clamps AZoom to [0.02, 20], re-anchors around the
      control center (world point at center stays fixed), then Invalidate.
      Fires OnZoomChanged after each change. }
    procedure SetZoomLevel(AZoom: Double);
    function  ZoomLevel: Double;

    property Zoom: Double read FZoom write FZoom;

  published
    property Align;
    property AlignWithMargins;
    property Anchors;
    property Color;
    property ParentBackground;
    property ParentColor;
    property ParentFont;
    property PopupMenu;
    property TabOrder;
    property TabStop default True;
    property Visible;
    property ShowLegend: Boolean read FShowLegend write FShowLegend default True;
    { When True (default), a plain left-click on a node that has children
      toggles its collapsed state (finding F6: "click a unit, see its
      methods").  Leaf nodes instead raise OnOpenSource on a plain click
      (finding F7).  Set False to restore select-only single-click. }
    property ExpandOnSingleClick: Boolean read FExpandOnSingleClick
                                          write FExpandOnSingleClick
                                          default True;

    property OnClick;
    property OnNodeClick:        TGraphNodeEvent  read FOnNodeClick
                                                  write FOnNodeClick;
    property OnNodeHover:        TGraphHoverEvent read FOnNodeHover
                                                  write FOnNodeHover;
    property OnSelectionChange:  TNotifyEvent     read FOnSelectionChange
                                                  write FOnSelectionChange;
    property OnOpenSource:       TGraphOpenSourceEvent read FOnOpenSource
                                                       write FOnOpenSource;
    property OnCrossDbJump:      TGraphNameEvent  read FOnCrossDbJump
                                                  write FOnCrossDbJump;
    { Fired after VM state changes (collapse/focus/select/nav/store/show-all).
      Host can use this to refresh UI elements that read VM counts. }
    property OnViewChanged:      TNotifyEvent     read FOnViewChanged
                                                  write FOnViewChanged;
    { Fired whenever FZoom changes (SetZoomLevel, wheel, FitToWindow).
      Host uses this to sync a zoom slider. }
    property OnZoomChanged:      TNotifyEvent     read FOnZoomChanged
                                                  write FOnZoomChanged;
  end;

implementation

const
  { Background + text palette }
  CL_BG       = TColor($00282828);
  CL_LABEL    = TColor($00E0E0E0);
  CL_SEL_BORDER = TColor($000080FF);  { 2-px selection border }
  CL_EXT_BORDER = TColor($00808080);  { gray dashed for external }
  CL_DEP_BORDER = TColor($000000FF);  { red for deprecated }

  NODE_RADIUS   = 12;      { default pixel radius for projection nodes }
  LEGEND_MARGIN = 8;
  LEGEND_SWATCH = 14;

{ ---------------------------------------------------------------------------- }

constructor TDragLintGraphControl.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle := ControlStyle + [csOpaque, csClickEvents, csCaptureMouse];
  Width  := 600;
  Height := 400;
  TabStop := True;
  Color := CL_BG;

  FVM     := nil;
  FLayout := TGraphLayout.Create;
  FPlaced := TDictionary<Integer, Boolean>.Create;
  FBoxScroll := TDictionary<Integer, Integer>.Create;

  FZoom    := 1.0;
  FOffsetX := 0;
  FOffsetY := 0;
  FShowLegend := True;
  FExpandOnSingleClick := True;
  FFocusActive := False;
  FProjValid := False;

  FAnimTimer := TTimer.Create(Self);
  FAnimTimer.Enabled  := False;
  FAnimTimer.Interval := 33;   { ~30 fps }
  FAnimTimer.OnTimer  := AnimTick;

  FHoverTimer := TTimer.Create(Self);
  FHoverTimer.Enabled  := False;
  FHoverTimer.Interval := 550;   { dwell before the hint pops }
  FHoverTimer.OnTimer  := HoverTick;
  FHintWin := nil;

  FDragNodeIdx := -1;

  { Right-click context menu (built in code so the control is self-contained). }
  FContextNodeIdx := -1;
  FPopup := TPopupMenu.Create(Self);

  FMiOpen := TMenuItem.Create(FPopup);
  FMiOpen.Caption := 'Open Source (Definition)';
  FMiOpen.OnClick := CtxOpenSource;
  FPopup.Items.Add(FMiOpen);

  FMiGotoIntf := TMenuItem.Create(FPopup);
  FMiGotoIntf.Caption := 'Go to Interface';
  FMiGotoIntf.OnClick := CtxGotoInterface;
  FPopup.Items.Add(FMiGotoIntf);

  FMiWhereUsed := TMenuItem.Create(FPopup);
  FMiWhereUsed.Caption := 'Where Used (focus neighborhood)';
  FMiWhereUsed.OnClick := CtxWhereUsed;
  FPopup.Items.Add(FMiWhereUsed);

  FMiCenter := TMenuItem.Create(FPopup);
  FMiCenter.Caption := 'Center Here';
  FMiCenter.OnClick := CtxCenter;
  FPopup.Items.Add(FMiCenter);

  { Canvas-level items -- always shown, so a right-click never does "nothing"
    even on empty space or a node the cursor narrowly missed. }
  FMiSep := TMenuItem.Create(FPopup);
  FMiSep.Caption := '-';
  FPopup.Items.Add(FMiSep);

  FMiBack := TMenuItem.Create(FPopup);
  FMiBack.Caption := 'Back (up one level)';
  FMiBack.OnClick := CtxBack;
  FPopup.Items.Add(FMiBack);

  FMiFit := TMenuItem.Create(FPopup);
  FMiFit.Caption := 'Fit to Window';
  FMiFit.OnClick := CtxFit;
  FPopup.Items.Add(FMiFit);
end;

destructor TDragLintGraphControl.Destroy;
begin
  FAnimTimer.Free;
  FLayout.Free;
  FPlaced.Free;
  FHoverTimer.Free;
  FHintWin.Free;
  FBoxScroll.Free;
  inherited;
end;

{ ---------------------------------------------------------------------------- }

procedure TDragLintGraphControl.Bind(const AVM: IGraphViewModel);
begin
  FVM := AVM;
  FProjValid := False;
  FPlaced.Clear;
  FBoxScroll.Clear;
  if FVM <> nil then
  begin
    { Present the store collapsed to its top level (finding F8): a fresh bind
      shows a handful of unit bubbles you drill into, instead of the whole
      expanded tree.  Done here (the View) rather than in the ViewModel so the
      VM's "a fresh load is fully expanded" contract is preserved.  Collapse
      before subscribing so this setup does not re-enter HandleVMChanged. }
    FVM.CollapseAll;
    FProjValid := False;
    FVM.SetOnChanged(HandleVMChanged);
    FVM.SetOnStoreChanged(HandleVMStoreChanged);
    Relayout;
  end;
  Invalidate;
end;

procedure TDragLintGraphControl.HandleVMChanged(Sender: TObject);
begin
  FProjValid := False;
  { Expand reveals new nodes -> seed + settle them; collapse/select place
    nothing new and return cheaply, leaving the view where the user left it. }
  EnsureLayout(False);
  Invalidate;
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
end;

procedure TDragLintGraphControl.HandleVMStoreChanged(Sender: TObject);
begin
  { New store -> node indices are no longer comparable; drop placement and
    present the new store collapsed to its top level (finding F8). }
  FPlaced.Clear;
  FBoxScroll.Clear;
  FVM.CollapseAll;
  FProjValid := False;
  Relayout;
  Invalidate;
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
end;

function TDragLintGraphControl.CurrentProjection: TGraphProjection;
begin
  if not FProjValid then
  begin
    FProjection := FVM.Projection;
    FProjValid := True;
  end;
  Result := FProjection;
end;

procedure TDragLintGraphControl.Relayout;
begin
  { Full (re)settle of the visible set -- used on Bind / store change. }
  EnsureLayout(True);
end;

procedure TDragLintGraphControl.EnsureLayout(AForceAll: Boolean);
const
  { Repulsion is O(V^2) in the *visible* node count V, so the cap only matters
    when a single expansion reveals thousands of siblings at once. }
  LAYOUT_LARGE_THRESHOLD = 2000;
  LAYOUT_LARGE_STEPS     = 5;
  LAYOUT_NORMAL_STEPS    = 200;
var
  Proj: TGraphProjection;
  VN, EN, ECount, I, NIdx, PIdx, NewCount, Steps: Integer;
  VisIdx, ESrc, EDst: TArray<Integer>;
  Vis: TDictionary<Integer, Boolean>;
  N, P: PGraphNode;
  W, H: Double;
begin
  if (FVM = nil) or (FVM.Data = nil) then Exit;
  if FVM.Data.NodeCount = 0 then Exit;

  Proj := CurrentProjection;
  VN := Length(Proj.Nodes);
  if VN = 0 then
  begin
    if AForceAll then FitToWindow;
    Exit;
  end;

  W := Width  * 2.0;  if W < 200 then W := 1200;
  H := Height * 2.0;  if H < 200 then H := 800;

  { Collect visible node indices; seed any node that has no position yet.
    Deterministic seed so test fixtures and repeated runs reproduce. }
  RandSeed := VN + 1;
  SetLength(VisIdx, VN);
  NewCount := 0;
  for I := 0 to VN - 1 do
  begin
    NIdx := Proj.Nodes[I].NodeIdx;
    VisIdx[I] := NIdx;
    N := FVM.Data.NodeAt(NIdx);
    if N.Radius < 1 then N.Radius := 12;
    if not FPlaced.ContainsKey(NIdx) then
    begin
      PIdx := FVM.Data.ParentIndexOf(NIdx);
      if (PIdx >= 0) and FPlaced.ContainsKey(PIdx) then
      begin
        { fan a revealed child out around its already-placed parent }
        P := FVM.Data.NodeAt(PIdx);
        N.X := P.X + (Random - 0.5) * 80.0;
        N.Y := P.Y + (Random - 0.5) * 80.0;
      end
      else
      begin
        N.X := Random * W - W / 2;
        N.Y := Random * H - H / 2;
      end;
      N.VX := 0;
      N.VY := 0;
      FPlaced.AddOrSetValue(NIdx, True);
      Inc(NewCount);
    end;
  end;

  { Incremental pass with nothing new to place -> positions already valid
    (e.g. a pure selection or a collapse).  Keep the user's pan/zoom. }
  if (NewCount = 0) and (not AForceAll) then Exit;

  { Edges fed to the layout = the projection's aggregated relation edges PLUS a
    synthetic containment spring (parent -> child) for every visible node whose
    parent is also visible.  The projection drops ekContains, so without this a
    revealed child has nothing pulling it toward its unit and repulsion scatters
    it off-screen -- which is why expanding a unit "did nothing" visible.  The
    spring makes a unit's members cluster around it on expand. }
  EN := Length(Proj.Edges);
  Vis := TDictionary<Integer, Boolean>.Create(VN);
  try
    for I := 0 to VN - 1 do
      Vis.AddOrSetValue(VisIdx[I], True);

    SetLength(ESrc, EN + VN);
    SetLength(EDst, EN + VN);
    for I := 0 to EN - 1 do
    begin
      ESrc[I] := Proj.Edges[I].SourceIdx;
      EDst[I] := Proj.Edges[I].TargetIdx;
    end;
    ECount := EN;
    for I := 0 to VN - 1 do
    begin
      PIdx := FVM.Data.ParentIndexOf(VisIdx[I]);
      if (PIdx >= 0) and Vis.ContainsKey(PIdx) then
      begin
        ESrc[ECount] := PIdx;
        EDst[ECount] := VisIdx[I];
        Inc(ECount);
      end;
    end;
    SetLength(ESrc, ECount);
    SetLength(EDst, ECount);
  finally
    Vis.Free;
  end;

  if VN > LAYOUT_LARGE_THRESHOLD then
    Steps := LAYOUT_LARGE_STEPS
  else
    Steps := LAYOUT_NORMAL_STEPS;

  FLayout.SetScale(VN, W, H);
  FLayout.StepVisible(FVM.Data, VisIdx, ESrc, EDst, Steps);

  { Nodes with no visible relation edge get no spring and the force pass just
    scatters them to the far corners (the unexplained "+22" stars the user
    saw).  Tuck them into a tidy grid beside the connected cluster instead. }
  PackIsolatedNodes(VisIdx, ESrc, EDst);

  { We only reach here when the visible set changed (full relayout, or an
    expand revealed new nodes -- a pure collapse/select returned earlier).
    Re-fit so the revealed members are actually on screen. }
  FitToWindow;
end;

procedure TDragLintGraphControl.PackIsolatedNodes(
  const AVisIdx, AESrc, AEDst: TArray<Integer>);
const
  CELL_W = 170.0;   { wide enough for a unit label + "(+N)" }
  CELL_H = 46.0;
  GAP_Y  = 80.0;    { clearance below the connected cluster }
var
  Connected: TDictionary<Integer, Boolean>;
  I, NIdx, M, Cols, Rows, R, C, K: Integer;
  HasConn: Boolean;
  MinX, MaxX, MaxY, CenterX: Double;
  N: PGraphNode;
  Isolated: TList<Integer>;
  GridW, Left, Top: Double;
begin
  if FVM = nil then Exit;
  Connected := TDictionary<Integer, Boolean>.Create;
  Isolated  := TList<Integer>.Create;
  try
    for I := 0 to High(AESrc) do Connected.AddOrSetValue(AESrc[I], True);
    for I := 0 to High(AEDst) do Connected.AddOrSetValue(AEDst[I], True);

    { Bounding box of the connected nodes (where the hairball sits). }
    HasConn := False;
    MinX :=  1.0E30; MaxX := -1.0E30; MaxY := -1.0E30;
    for I := 0 to High(AVisIdx) do
    begin
      NIdx := AVisIdx[I];
      if Connected.ContainsKey(NIdx) then
      begin
        HasConn := True;
        N := FVM.Data.NodeAt(NIdx);
        if N.X < MinX then MinX := N.X;
        if N.X > MaxX then MaxX := N.X;
        if N.Y > MaxY then MaxY := N.Y;
      end
      else
        Isolated.Add(NIdx);
    end;

    M := Isolated.Count;
    if M = 0 then Exit;

    if not HasConn then
    begin
      { Nothing is connected (common at the all-projects top level): centre the
        whole grid on the origin so Fit frames a clean lattice, not a hairball. }
      MinX := 0; MaxX := 0; MaxY := -GAP_Y;
    end;

    { Wider-than-tall grid (labels are wide). }
    Cols := Trunc(Sqrt(M * 1.8)); if Cols < 1 then Cols := 1;
    Rows := (M + Cols - 1) div Cols;
    GridW   := Cols * CELL_W;
    CenterX := (MinX + MaxX) / 2;
    Left := CenterX - GridW / 2;
    Top  := MaxY + GAP_Y;

    for K := 0 to M - 1 do
    begin
      R := K div Cols;
      C := K mod Cols;
      N := FVM.Data.NodeAt(Isolated[K]);
      N.X  := Left + C * CELL_W + CELL_W / 2;
      N.Y  := Top  + R * CELL_H + CELL_H / 2;
      N.VX := 0;
      N.VY := 0;
    end;
    if Rows = 0 then ;  { silence "Rows assigned but not used" on some configs }
  finally
    Isolated.Free;
    Connected.Free;
  end;
end;

procedure TDragLintGraphControl.AnimTick(Sender: TObject);
var
  Proj: TGraphProjection;
  VisIdx, ESrc, EDst: TArray<Integer>;
  I: Integer;
  Done: Boolean;
begin
  if FVM = nil then Exit;
  Proj := CurrentProjection;
  if Length(Proj.Nodes) = 0 then
  begin
    FAnimTimer.Enabled := False;
    Exit;
  end;
  SetLength(VisIdx, Length(Proj.Nodes));
  for I := 0 to High(Proj.Nodes) do
    VisIdx[I] := Proj.Nodes[I].NodeIdx;
  SetLength(ESrc, Length(Proj.Edges));
  SetLength(EDst, Length(Proj.Edges));
  for I := 0 to High(Proj.Edges) do
  begin
    ESrc[I] := Proj.Edges[I].SourceIdx;
    EDst[I] := Proj.Edges[I].TargetIdx;
  end;
  { Progressive settle of the visible set only.  Positions are read live from
    TGraphData at paint, so the projection cache stays valid -- no rebuild. }
  Done := FLayout.StepVisible(FVM.Data, VisIdx, ESrc, EDst, 1);
  Invalidate;
  if Done then FAnimTimer.Enabled := False;
end;

{ ---------------------------------------------------------------------------- }

procedure TDragLintGraphControl.FitToWindow;
var
  Proj: TGraphProjection;
  MinX, MaxX, MinY, MaxY: Double;
  I: Integer;
  N: PGraphNode;
  SpanX, SpanY: Double;
  ZoomX, ZoomY: Double;
begin
  Proj := CurrentProjection;
  if (FVM = nil) or (Length(Proj.Nodes) = 0) then
  begin
    FZoom := 1.0; FOffsetX := 0; FOffsetY := 0;
    Invalidate;
    if Assigned(FOnZoomChanged) then FOnZoomChanged(Self);
    Exit;
  end;
  MinX :=  1.0E30; MaxX := -1.0E30;
  MinY :=  1.0E30; MaxY := -1.0E30;
  for I := 0 to High(Proj.Nodes) do
  begin
    N := FVM.Data.NodeAt(Proj.Nodes[I].NodeIdx);
    if N.X < MinX then MinX := N.X;
    if N.X > MaxX then MaxX := N.X;
    if N.Y < MinY then MinY := N.Y;
    if N.Y > MaxY then MaxY := N.Y;
  end;
  SpanX := MaxX - MinX; if SpanX < 1 then SpanX := 1;
  SpanY := MaxY - MinY; if SpanY < 1 then SpanY := 1;
  ZoomX := (Width  - 40) / SpanX;
  ZoomY := (Height - 40) / SpanY;
  FZoom := Min(ZoomX, ZoomY);
  if FZoom > 2.0  then FZoom := 2.0;
  if FZoom < 0.02 then FZoom := 0.02;
  FOffsetX := (MinX + MaxX) / 2;
  FOffsetY := (MinY + MaxY) / 2;
  Invalidate;
  if Assigned(FOnZoomChanged) then FOnZoomChanged(Self);
end;

{ ---------------------------------------------------------------------------- }

procedure TDragLintGraphControl.SetZoomLevel(AZoom: Double);
begin
  { Clamp }
  if AZoom < 0.02 then AZoom := 0.02;
  if AZoom > 20.0 then AZoom := 20.0;
  if AZoom = FZoom then Exit;
  { Center-anchored zoom: FOffsetX/Y are the world point at screen center, so
    changing only FZoom keeps that world point fixed -- no offset adjustment needed. }
  FZoom := AZoom;
  Invalidate;
  if Assigned(FOnZoomChanged) then FOnZoomChanged(Self);
end;

function TDragLintGraphControl.ZoomLevel: Double;
begin
  Result := FZoom;
end;

{ ---------------------------------------------------------------------------- }

function TDragLintGraphControl.WorldToScreen(WX, WY: Double): TPoint;
begin
  Result.X := Round((WX - FOffsetX) * FZoom + Width  / 2);
  Result.Y := Round((WY - FOffsetY) * FZoom + Height / 2);
end;

function TDragLintGraphControl.ScreenToWorld(SX, SY: Integer): TPointF;
begin
  Result.X := (SX - Width  / 2) / FZoom + FOffsetX;
  Result.Y := (SY - Height / 2) / FZoom + FOffsetY;
end;

{ Returns index into AProj.Nodes or -1 }
function TDragLintGraphControl.HitTestProjNode(SX, SY: Integer;
  const AProj: TGraphProjection): Integer;
var
  I:          Integer;
  PN:         TProjNode;
  N:          PGraphNode;
  P:          TPoint;
  DX, DY:     Integer;
  RadiusPx:   Integer;
  NS:         TNodeStyle;
  IsBox, LabelShown: Boolean;
  S, Glyph:   string;
  LW, LH, BL, BT, BR, BB: Integer;
begin
  Result := -1;
  if FVM = nil then Exit;
  Canvas.Font.Size := 8;   { match the draw font so label widths line up }
  for I := High(AProj.Nodes) downto 0 do
  begin
    PN := AProj.Nodes[I];
    N  := FVM.Data.NodeAt(PN.NodeIdx);
    P  := WorldToScreen(N.X, N.Y);

    { 1. the node centre / shape. }
    DX := SX - P.X;
    DY := SY - P.Y;
    RadiusPx := Round(N.Radius * FZoom);
    if RadiusPx < 6 then RadiusPx := 6;
    if (DX * DX + DY * DY) <= (RadiusPx * RadiusPx) then
      Exit(I);

    { 2. the drawn label -- a far bigger target than the centre dot.  Without
      this, the wide unit boxes and the packed/collapsed strays are almost
      unclickable (the user's "clicking does nothing").  Only test it when a
      label is actually drawn (box nodes always; others gated like the paint). }
    NS    := NodeStyleFor(N.Kind);
    IsBox := NS.Shape in [nsBox, nsRoundBox];
    LabelShown := IsBox or (FZoom >= 0.6) or (N.Id = FVM.SelectedId) or PN.Collapsed;
    if not LabelShown then Continue;

    S := N.Label_;
    if S = '' then S := N.Id;
    Glyph := VisibilityGlyph(N.Modifiers);
    if Glyph <> '' then S := Glyph + ' ' + S;
    if PN.Collapsed then
      S := S + ' (+' + IntToStr(FVM.Data.DescendantCount(PN.NodeIdx)) + ')';
    LW := Canvas.TextWidth(S);
    LH := Canvas.TextHeight('Ay');

    if IsBox then
    begin   { label centred inside the box at P }
      BL := P.X - LW div 2 - 8;  BR := P.X + LW div 2 + 8;
      BT := P.Y - LH div 2 - 5;  BB := P.Y + LH div 2 + 5;
    end
    else
    begin   { label below the shape }
      BL := P.X - LW div 2 - 3;  BR := P.X + LW div 2 + 3;
      BT := P.Y + RadiusPx;      BB := P.Y + RadiusPx + LH + 4;
    end;
    if (SX >= BL) and (SX <= BR) and (SY >= BT) and (SY <= BB) then
      Exit(I);
  end;
end;

{ Returns index into AProj.Edges or -1 (point-to-segment < 4 px) }
function TDragLintGraphControl.HitTestProjEdge(SX, SY: Integer;
  const AProj: TGraphProjection): Integer;
var
  I:          Integer;
  PE:         TProjEdge;
  A, B:       TPoint;
  NA, NB:     PGraphNode;
  ABX, ABY:   Double;
  APX, APY:   Double;
  T, Len2:    Double;
  CX, CY:     Double;
  Dist:       Double;
begin
  Result := -1;
  if FVM = nil then Exit;
  for I := 0 to High(AProj.Edges) do
  begin
    PE := AProj.Edges[I];
    NA := FVM.Data.NodeAt(PE.SourceIdx);
    NB := FVM.Data.NodeAt(PE.TargetIdx);
    A  := WorldToScreen(NA.X, NA.Y);
    B  := WorldToScreen(NB.X, NB.Y);
    ABX := B.X - A.X;  ABY := B.Y - A.Y;
    APX := SX  - A.X;  APY := SY  - A.Y;
    Len2 := ABX * ABX + ABY * ABY;
    if Len2 < 1 then Continue;
    T := (APX * ABX + APY * ABY) / Len2;
    if T < 0 then T := 0 else if T > 1 then T := 1;
    CX := A.X + T * ABX;
    CY := A.Y + T * ABY;
    Dist := Sqrt((SX - CX) * (SX - CX) + (SY - CY) * (SY - CY));
    if Dist < 4.0 then
    begin
      Result := I;
      Exit;
    end;
  end;
end;

{ ---------------------------------------------------------------------------- }

function TDragLintGraphControl.HandleUmlBoxClick(SX, SY: Integer): Boolean;
var
  I, RowIdx: Integer;
  HB: TUmlBoxHit;
  TypeNode, MemberNode: PGraphNode;
begin
  Result := False;
  if FVM = nil then Exit;
  { last-drawn first, so a box on top wins }
  for I := High(FUmlBoxes) downto 0 do
  begin
    HB := FUmlBoxes[I];
    if (SX < HB.Box.Left) or (SX >= HB.Box.Right) or
       (SY < HB.Box.Top) or (SY >= HB.Box.Bottom) then
      Continue;

    TypeNode := FVM.Data.NodeAt(HB.NodeIdx);
    FVM.SelectNode(TypeNode.Id);

    { member row -> open that member }
    if (SY >= HB.RowTop) and (HB.RowH > 0) then
    begin
      RowIdx := (SY - HB.RowTop) div HB.RowH;
      if (RowIdx >= 0) and (RowIdx < Length(HB.Members)) then
      begin
        MemberNode := FVM.Data.NodeAt(HB.Members[RowIdx]);
        if Assigned(FOnOpenSource) then
          FOnOpenSource(Self, MemberNode);
        Invalidate;
        if Assigned(FOnSelectionChange) then FOnSelectionChange(Self);
        Exit(True);
      end;
    end;

    { title bar (or empty area) -> open the type itself }
    if Assigned(FOnOpenSource) then
      FOnOpenSource(Self, TypeNode);
    Invalidate;
    if Assigned(FOnSelectionChange) then FOnSelectionChange(Self);
    Exit(True);
  end;
end;

function TDragLintGraphControl.NodeIdxAt(SX, SY: Integer): Integer;
var
  I, RowIdx, NIdx: Integer;
  HB: TUmlBoxHit;
  Proj: TGraphProjection;
begin
  Result := -1;
  if FVM = nil then Exit;
  { UML boxes first: a member row resolves to that member, else the type }
  for I := High(FUmlBoxes) downto 0 do
  begin
    HB := FUmlBoxes[I];
    if (SX < HB.Box.Left) or (SX >= HB.Box.Right) or
       (SY < HB.Box.Top) or (SY >= HB.Box.Bottom) then
      Continue;
    if (SY >= HB.RowTop) and (HB.RowH > 0) then
    begin
      RowIdx := (SY - HB.RowTop) div HB.RowH;
      if (RowIdx >= 0) and (RowIdx < Length(HB.Members)) then
        Exit(HB.Members[RowIdx]);
    end;
    Exit(HB.NodeIdx);
  end;
  { circle nodes }
  Proj := CurrentProjection;
  NIdx := HitTestProjNode(SX, SY, Proj);
  if NIdx >= 0 then
    Result := Proj.Nodes[NIdx].NodeIdx;
end;

function TDragLintGraphControl.MovableNodeAt(SX, SY: Integer): Integer;
var
  I, NIdx: Integer;
  HB: TUmlBoxHit;
  Proj: TGraphProjection;
begin
  Result := -1;
  if FVM = nil then Exit;
  { a UML box drags as a whole -> return its type node, not a member row }
  for I := High(FUmlBoxes) downto 0 do
  begin
    HB := FUmlBoxes[I];
    if (SX >= HB.Box.Left) and (SX < HB.Box.Right) and
       (SY >= HB.Box.Top) and (SY < HB.Box.Bottom) then
      Exit(HB.NodeIdx);
  end;
  Proj := CurrentProjection;
  NIdx := HitTestProjNode(SX, SY, Proj);
  if NIdx >= 0 then
    Result := Proj.Nodes[NIdx].NodeIdx;
end;

procedure TDragLintGraphControl.ShowContextMenu(SX, SY: Integer);
var
  P: TPoint;
  N: PGraphNode;
  HasIntf: Boolean;
  I, Other: Integer;
  Proj: TGraphProjection;
begin
  FContextNodeIdx := NodeIdxAt(SX, SY);

  { Node items show only when the click landed on a node; the canvas items
    (Back / Fit) always show so the menu is never empty. }
  FMiOpen.Visible      := FContextNodeIdx >= 0;
  FMiGotoIntf.Visible  := FContextNodeIdx >= 0;
  FMiWhereUsed.Visible := FContextNodeIdx >= 0;
  FMiCenter.Visible    := FContextNodeIdx >= 0;
  FMiSep.Visible       := FContextNodeIdx >= 0;
  FMiBack.Enabled      := (FVM <> nil) and
    ((Length(FVM.DrillPath) > 0) or FVM.ShowAllTopLevel or FVM.CanGoBack);

  if FContextNodeIdx >= 0 then
  begin
    N := FVM.Data.NodeAt(FContextNodeIdx);

    { right-click also selects, so the status bar / highlight follow }
    FVM.SelectNode(N.Id);
    Invalidate;
    if Assigned(FOnSelectionChange) then FOnSelectionChange(Self);

    FMiOpen.Enabled := (N.FilePath <> '') and Assigned(FOnOpenSource);

    { enable "Go to Interface" only when an edge connects this node to one }
    HasIntf := False;
    Proj := CurrentProjection;
    for I := 0 to High(Proj.Edges) do
    begin
      Other := -1;
      if Proj.Edges[I].SourceIdx = FContextNodeIdx then
        Other := Proj.Edges[I].TargetIdx
      else if Proj.Edges[I].TargetIdx = FContextNodeIdx then
        Other := Proj.Edges[I].SourceIdx;
      if (Other >= 0) and (FVM.Data.NodeAt(Other).Kind = nkInterface) then
      begin
        HasIntf := True;
        Break;
      end;
    end;
    FMiGotoIntf.Enabled := HasIntf;
  end;

  P := ClientToScreen(Point(SX, SY));
  FPopup.Popup(P.X, P.Y);
end;

procedure TDragLintGraphControl.CtxOpenSource(Sender: TObject);
begin
  if (FVM = nil) or (FContextNodeIdx < 0) then Exit;
  if Assigned(FOnOpenSource) then
    FOnOpenSource(Self, FVM.Data.NodeAt(FContextNodeIdx));
end;

procedure TDragLintGraphControl.CtxWhereUsed(Sender: TObject);
var
  N: PGraphNode;
begin
  if (FVM = nil) or (FContextNodeIdx < 0) then Exit;
  N := FVM.Data.NodeAt(FContextNodeIdx);
  FVM.SetFocus(N.Id, 1);          { dim to the 1-hop neighborhood }
  FFocusActive := True;
  FProjValid := False;
  Invalidate;
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
end;

procedure TDragLintGraphControl.CtxGotoInterface(Sender: TObject);
var
  I, Other: Integer;
  Proj: TGraphProjection;
begin
  if (FVM = nil) or (FContextNodeIdx < 0) then Exit;
  Proj := CurrentProjection;
  for I := 0 to High(Proj.Edges) do
  begin
    Other := -1;
    if Proj.Edges[I].SourceIdx = FContextNodeIdx then
      Other := Proj.Edges[I].TargetIdx
    else if Proj.Edges[I].TargetIdx = FContextNodeIdx then
      Other := Proj.Edges[I].SourceIdx;
    if (Other >= 0) and (FVM.Data.NodeAt(Other).Kind = nkInterface) then
    begin
      FVM.SelectNode(FVM.Data.NodeAt(Other).Id);
      Invalidate;
      if Assigned(FOnSelectionChange) then FOnSelectionChange(Self);
      Exit;
    end;
  end;
end;

procedure TDragLintGraphControl.CtxCenter(Sender: TObject);
var
  N: PGraphNode;
begin
  if (FVM = nil) or (FContextNodeIdx < 0) then Exit;
  N := FVM.Data.NodeAt(FContextNodeIdx);
  FOffsetX := N.X;   { FOffsetX/Y is the world point at screen center }
  FOffsetY := N.Y;
  Invalidate;
  if Assigned(FOnZoomChanged) then FOnZoomChanged(Self);
end;

procedure TDragLintGraphControl.CtxFit(Sender: TObject);
begin
  FitToWindow;
end;

procedure TDragLintGraphControl.CtxBack(Sender: TObject);
begin
  NavigateBack;
end;

procedure TDragLintGraphControl.NavigateBack;
begin
  if FVM = nil then Exit;
  { One predictable "up": leave a drill level, else collapse a show-all, else
    pop the neighborhood-nav stack.  Nothing left to do -> no-op. }
  if Length(FVM.DrillPath) > 0 then
    FVM.DrillToDepth(Length(FVM.DrillPath) - 1)
  else if FVM.ShowAllTopLevel then
    FVM.SetShowAllTopLevel(False)
  else if FVM.CanGoBack then
    FVM.Back
  else
    Exit;
  FProjValid := False;
  Relayout;                       { re-settle + Fit so the parent view frames }
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
end;

procedure TDragLintGraphControl.WMXButtonUp(var Msg: TMessage);
const
  XBUTTON1 = $0001;   { the "back" thumb button }
begin
  inherited;
  { HiWord(wParam) says which X button; treat the back thumb as "up one". }
  if HiWord(LongWord(Msg.WParam)) and XBUTTON1 <> 0 then
  begin
    NavigateBack;
    Msg.Result := 1;
  end;
end;

procedure TDragLintGraphControl.DrawArrowHead(PA, PB: TPoint);
var
  DX, DY, Len: Double;
  UX, UY:      Double;
  LX, LY:      Integer;
  RX, RY:      Integer;
  AX, AY:      Integer;  { tip }
  Pts:         array[0..2] of TPoint;
begin
  DX := PB.X - PA.X;  DY := PB.Y - PA.Y;
  Len := Sqrt(DX * DX + DY * DY);
  if Len < 2 then Exit;
  UX := DX / Len;  UY := DY / Len;
  { tip is 5px back from PB (smaller, less obtrusive arrowhead) }
  AX := PB.X - Round(UX * 5);
  AY := PB.Y - Round(UY * 5);
  { left/right wing 3px perpendicular, 5px back from tip }
  LX := AX - Round(UX * 5) + Round(UY * 3);
  LY := AY - Round(UY * 5) - Round(UX * 3);
  RX := AX - Round(UX * 5) - Round(UY * 3);
  RY := AY - Round(UY * 5) + Round(UX * 3);
  Pts[0] := Point(AX, AY);
  Pts[1] := Point(LX, LY);
  Pts[2] := Point(RX, RY);
  Canvas.Polygon(Pts);
end;

procedure TDragLintGraphControl.DrawEdges(const AProj: TGraphProjection);
var
  I:        Integer;
  PE:       TProjEdge;
  NA, NB:   PGraphNode;
  PA, PB:   TPoint;
  Sty:      TEdgeStyle;
  OldStyle: TPenStyle;
  OldWidth: Integer;
  OldColor: TColor;
  Alpha:    TColor;
begin
  OldStyle := Canvas.Pen.Style;
  OldWidth := Canvas.Pen.Width;
  OldColor := Canvas.Pen.Color;
  for I := 0 to High(AProj.Edges) do
  begin
    PE  := AProj.Edges[I];
    NA  := FVM.Data.NodeAt(PE.SourceIdx);
    NB  := FVM.Data.NodeAt(PE.TargetIdx);
    PA  := WorldToScreen(NA.X, NA.Y);
    PB  := WorldToScreen(NB.X, NB.Y);
    Sty := EdgeStyleFor(PE.Kind, PE.Section, PE.Aggregated, PE.CrossDb);

    { UML "implements/inherits": a type-use edge between a class/record and an
      interface is a realization -- draw it distinct (dashed, UML cyan) so you
      can spot who implements an interface. View-only; no reindex needed. }
    if (PE.Kind = ekTypeRef) and (not PE.Aggregated) and
       (((NA.Kind = nkInterface) and (NB.Kind in [nkClass, nkRecord])) or
        ((NB.Kind = nkInterface) and (NA.Kind in [nkClass, nkRecord]))) then
    begin
      Sty.Color := Cardinal($00C0C000);   { cyan-ish, distinct from type refs }
      Sty.Dash  := edDash;
      Sty.Arrow := True;
    end;

    Canvas.Pen.Color := TColor(Sty.Color);
    Canvas.Pen.Width := Sty.Width;
    case Sty.Dash of
      edSolid: Canvas.Pen.Style := psSolid;
      edDash:  Canvas.Pen.Style := psDash;
      edBold:
        begin
          Canvas.Pen.Style := psSolid;
          Canvas.Pen.Width := 3;
        end;
    end;
    if PE.Dimmed then
    begin
      { lighten color: blend half toward background }
      Alpha := Canvas.Pen.Color;
      Canvas.Pen.Color := RGB(
        (GetRValue(Alpha) + GetRValue(CL_BG)) div 2,
        (GetGValue(Alpha) + GetGValue(CL_BG)) div 2,
        (GetBValue(Alpha) + GetBValue(CL_BG)) div 2
      );
    end;
    Canvas.MoveTo(PA.X, PA.Y);
    Canvas.LineTo(PB.X, PB.Y);
    if Sty.Arrow then
    begin
      Canvas.Brush.Color := Canvas.Pen.Color;
      Canvas.Pen.Style   := psSolid;
      DrawArrowHead(PA, PB);
    end;
  end;
  Canvas.Pen.Style := OldStyle;
  Canvas.Pen.Width := OldWidth;
  Canvas.Pen.Color := OldColor;
end;

procedure TDragLintGraphControl.DrawUmlTypeBox(ANode: PGraphNode;
  ANodeIdx: Integer; const ACenter: TPoint; ASelected: Boolean);
const
  PAD = 4;
  MAX_ROWS = 12;
var
  Children: TArray<Integer>;
  Rows: TArray<string>;
  Title, G, Ind: string;
  I, W, H, RowH, TitleH, BoxL, BoxT, Y, Shown, Total, Offset, MaxOff,
    RowsTop: Integer;
  HasAbove, HasBelow: Boolean;
  M: PGraphNode;
  NS: TNodeStyle;
  Hit: TUmlBoxHit;
begin
  Children := FVM.Data.ChildrenOf(ANodeIdx);
  Total := Length(Children);
  Title := ANode.Label_;
  if Title = '' then Title := ANode.Id;
  if ANode.Kind = nkInterface then
    Title := '<<interface>> ' + Title
  else if ANode.Kind = nkRecord then
    Title := '<<record>> ' + Title;
  if ANode.Section = 'implementation' then
    Title := Title + '  [impl-only]';   { not usable from another unit }

  Canvas.Font.Size := 8;
  Canvas.Font.Style := [fsBold];
  RowH := Canvas.TextHeight('Ay') + 2;
  TitleH := RowH + 2;
  W := Canvas.TextWidth(Title);

  { scroll window: wheel over the box sets FBoxScroll[ANodeIdx]; clamp it }
  if not FBoxScroll.TryGetValue(ANodeIdx, Offset) then Offset := 0;
  MaxOff := Total - MAX_ROWS;
  if MaxOff < 0 then MaxOff := 0;
  if Offset < 0 then Offset := 0;
  if Offset > MaxOff then Offset := MaxOff;
  Shown := Total - Offset;
  if Shown > MAX_ROWS then Shown := MAX_ROWS;
  HasAbove := Offset > 0;
  HasBelow := (Offset + Shown) < Total;

  SetLength(Rows, Shown);
  Canvas.Font.Style := [];
  for I := 0 to Shown - 1 do
  begin
    M := FVM.Data.NodeAt(Children[Offset + I]);
    G := VisibilityGlyph(M.Modifiers);
    if G = '' then G := ' ';
    Rows[I] := G + ' ' + M.Label_;
    if M.Signature <> '' then            { field/return type }
      Rows[I] := Rows[I] + ': ' + M.Signature;
    if Canvas.TextWidth(Rows[I]) > W then W := Canvas.TextWidth(Rows[I]);
  end;
  if HasAbove or HasBelow then
  begin
    Ind := Format('-- %d-%d of %d (wheel to scroll) --',
      [Offset + 1, Offset + Shown, Total]);
    if Canvas.TextWidth(Ind) > W then W := Canvas.TextWidth(Ind);
  end;

  W := W + 2 * PAD;
  H := TitleH + Shown * RowH + PAD;
  if HasAbove then Inc(H, RowH);
  if HasBelow then Inc(H, RowH);

  BoxL := ACenter.X - W div 2;
  BoxT := ACenter.Y - H div 2;

  { body }
  Canvas.Brush.Color := TColor($00202828);
  Canvas.Brush.Style := bsSolid;
  if ASelected then
  begin
    Canvas.Pen.Color := CL_SEL_BORDER;
    Canvas.Pen.Width := 2;
  end
  else
  begin
    Canvas.Pen.Color := TColor($00606060);
    Canvas.Pen.Width := 1;
  end;
  Canvas.Pen.Style := psSolid;
  Canvas.RoundRect(BoxL, BoxT, BoxL + W, BoxT + H, 9, 9);

  { title + kind-colored separator }
  NS := NodeStyleFor(ANode.Kind);
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := CL_LABEL;
  Canvas.TextOut(BoxL + PAD, BoxT + 1, Title);
  Canvas.Pen.Color := TColor(NS.Fill);
  Canvas.Pen.Width := 2;
  Canvas.MoveTo(BoxL + 3, BoxT + TitleH);
  Canvas.LineTo(BoxL + W - 3, BoxT + TitleH);

  { member rows, with scroll indicators above/below }
  Canvas.Font.Style := [];
  Y := BoxT + TitleH + 1;
  if HasAbove then
  begin
    Canvas.Font.Color := TColor($00A0A0A0);
    Canvas.TextOut(BoxL + PAD, Y, Format('^ %d more above', [Offset]));
    Inc(Y, RowH);
  end;
  RowsTop := Y;          { first real member row -> hit-test anchor }
  Canvas.Font.Color := CL_LABEL;
  for I := 0 to Shown - 1 do
  begin
    Canvas.TextOut(BoxL + PAD, Y, Rows[I]);
    Inc(Y, RowH);
  end;
  if HasBelow then
  begin
    Canvas.Font.Color := TColor($00A0A0A0);
    Canvas.TextOut(BoxL + PAD, Y,
      Format('v %d more below', [Total - Offset - Shown]));
  end;

  { record geometry: RowTop is the first member row, Members is the visible
    window, so a row click maps to the right member even when scrolled. }
  Hit.NodeIdx := ANodeIdx;
  Hit.Box     := Rect(BoxL, BoxT, BoxL + W, BoxT + H);
  Hit.RowTop  := RowsTop;
  Hit.RowH    := RowH;
  SetLength(Hit.Members, Shown);
  for I := 0 to Shown - 1 do
    Hit.Members[I] := Children[Offset + I];
  FUmlBoxes := FUmlBoxes + [Hit];
end;

procedure TDragLintGraphControl.DrawNodes(const AProj: TGraphProjection);
const
  NODE_W = 28;   { pixel width for box shapes }
  NODE_H = 20;   { pixel height for box shapes }
var
  I:        Integer;
  PN:       TProjNode;
  N:        PGraphNode;
  P:        TPoint;
  R:        Integer;
  S:        string;
  Glyph:    string;
  NS:       TNodeStyle;
  FillCol:  TColor;
  BgR, BgG, BgB: Integer;
  FR, FG, FB:    Integer;
  TextH:    Integer;
  Badge:    string;
  DescN:    Integer;
  SelId:    string;
begin
  if FVM = nil then Exit;
  SelId := FVM.SelectedId;
  TextH := Canvas.TextHeight('A');
  SetLength(FUmlBoxes, 0);   { rebuilt below as UML boxes are drawn }

  for I := 0 to High(AProj.Nodes) do
  begin
    PN := AProj.Nodes[I];
    N  := FVM.Data.NodeAt(PN.NodeIdx);
    P  := WorldToScreen(N.X, N.Y);
    R  := Round(N.Radius * FZoom);
    if R < 4 then R := 4;

    NS := NodeStyleFor(N.Kind);
    FillCol := TColor(NS.Fill);

    { UML class-box: classes/interfaces/records list their members inside a
      titled frame (Phase 5).  Drawn when zoomed in enough to read, or when
      selected; at low zoom they fall through to the compact rounded-rect so
      the overview stays fast and uncluttered.  Members are read from
      TGraphData, so they are never also drawn as separate nodes. }
    if (N.Kind in [nkClass, nkInterface, nkRecord]) and
       ((FZoom >= 0.4) or (N.Id = SelId)) then
    begin
      DrawUmlTypeBox(N, PN.NodeIdx, P, N.Id = SelId);
      Continue;
    end;

    { Dimmed: blend fill toward background }
    if PN.Dimmed then
    begin
      BgR := GetRValue(CL_BG); BgG := GetGValue(CL_BG); BgB := GetBValue(CL_BG);
      FR  := GetRValue(FillCol); FG := GetGValue(FillCol); FB := GetBValue(FillCol);
      FillCol := RGB((FR + BgR) div 2, (FG + BgG) div 2, (FB + BgB) div 2);
    end;

    { Selection override -- hover highlight removed (bug F1) }
    if N.Id = SelId then
      Canvas.Pen.Color := CL_SEL_BORDER
    else if N.Deprecated then
      Canvas.Pen.Color := CL_DEP_BORDER
    else if N.IsExternal then
      Canvas.Pen.Color := CL_EXT_BORDER
    else
      Canvas.Pen.Color := TColor($00404040);

    if N.Id = SelId then
      Canvas.Pen.Width := 2
    else
      Canvas.Pen.Width := 1;

    Canvas.Brush.Color := FillCol;
    Canvas.Brush.Style := bsSolid;

    { External: dashed border }
    if N.IsExternal and (N.Id <> SelId) then
      Canvas.Pen.Style := psDash
    else
      Canvas.Pen.Style := psSolid;

    { Compose the label up front: glyph prefix for members, collapsed count. }
    S := N.Label_;
    if S = '' then S := N.Id;
    Glyph := VisibilityGlyph(N.Modifiers);
    if Glyph <> '' then
      S := Glyph + ' ' + S;
    if PN.Collapsed then
    begin
      DescN := FVM.Data.DescendantCount(PN.NodeIdx);
      S := S + ' (+' + IntToStr(DescN) + ')';
    end;

    if NS.Shape in [nsBox, nsRoundBox] then
    begin
      { Rectangle node (unit / project / SQL table / DFM form): a slightly
        rounded frame sized to fit the label, with the label drawn INSIDE.
        Text colour follows the fill luminance so it stays readable. }
      Canvas.Font.Size := 8;
      var BW: Integer := Canvas.TextWidth(S) + 14;
      var BH: Integer := Canvas.TextHeight('Ay') + 8;
      var BL: Integer := P.X - BW div 2;
      var BT: Integer := P.Y - BH div 2;
      Canvas.RoundRect(BL, BT, BL + BW, BT + BH, 9, 9);
      var Lum: Integer := (GetRValue(FillCol) * 299 + GetGValue(FillCol) * 587 +
                           GetBValue(FillCol) * 114) div 1000;
      Canvas.Brush.Style := bsClear;
      if Lum > 140 then
        Canvas.Font.Color := clBlack
      else
        Canvas.Font.Color := CL_LABEL;
      Canvas.TextOut(P.X - Canvas.TextWidth(S) div 2,
                     P.Y - Canvas.TextHeight(S) div 2, S);
      Canvas.Pen.Style := psSolid;
      Canvas.Pen.Width := 1;
    end
    else
    begin
      { Ellipse (free proc/func/other) + diamond/hexagon/etc. fallbacks. }
      if NS.Shape = nsEllipse then
        Canvas.Ellipse(P.X - R, P.Y - R, P.X + R, P.Y + R)
      else
        Canvas.RoundRect(P.X - NODE_W div 2, P.Y - NODE_H div 2,
                         P.X + NODE_W div 2, P.Y + NODE_H div 2, 5, 5);

      Canvas.Pen.Style := psSolid;
      Canvas.Pen.Width := 1;

      { Collapsed badge "+N" }
      if PN.Collapsed then
      begin
        DescN := FVM.Data.DescendantCount(PN.NodeIdx);
        Badge := '+' + IntToStr(DescN);
        Canvas.Brush.Color := TColor($00FF8000);
        Canvas.Brush.Style := bsSolid;
        Canvas.Pen.Color   := TColor($00202020);
        Canvas.Pen.Width   := 1;
        Canvas.RoundRect(P.X + R - 2, P.Y - R - 2,
                          P.X + R + Canvas.TextWidth(Badge) + 4,
                          P.Y - R + TextH + 2, 3, 3);
        Canvas.Brush.Style := bsClear;
        Canvas.Font.Color  := TColor($00FFFFFF);
        Canvas.Font.Size   := 7;
        Canvas.TextOut(P.X + R + 1, P.Y - R, Badge);
      end;

      { Label below the shape (zoom-gated, or always for the selection or a
        collapsed node -- otherwise a far-flung collapsed stray shows only its
        bare "+N" badge with no name, which users could not identify). }
      if (FZoom >= 0.6) or (N.Id = SelId) or PN.Collapsed then
      begin
        Canvas.Font.Size := 8;
        if (N.Id = SelId) and (FZoom < 0.6) then
        begin
          Canvas.Font.Color  := CL_LABEL;
          Canvas.Brush.Color := TColor($00303060);
          Canvas.Brush.Style := bsSolid;
          Canvas.Pen.Color   := CL_SEL_BORDER;
          Canvas.Pen.Width   := 1;
          Canvas.Pen.Style   := psSolid;
          Canvas.Rectangle(
            P.X - Canvas.TextWidth(S) div 2 - 2, P.Y + R + 1,
            P.X + Canvas.TextWidth(S) div 2 + 2,
            P.Y + R + Canvas.TextHeight(S) + 3);
          Canvas.Brush.Style := bsClear;
          Canvas.TextOut(P.X - Canvas.TextWidth(S) div 2, P.Y + R + 2, S);
        end
        else
        begin
          Canvas.Brush.Style := bsClear;
          Canvas.Font.Color  := CL_LABEL;
          Canvas.TextOut(P.X - Canvas.TextWidth(S) div 2, P.Y + R + 2, S);
        end;
      end;
    end;
  end;
end;

procedure TDragLintGraphControl.DrawLegend(const AProj: TGraphProjection);
const
  KIND_NAMES: array[TGraphNodeKind] of string = (
    'Unit', 'Type', 'Class', 'Interface', 'Record', 'Procedure', 'Function',
    'Method', 'Field', 'Property', 'Const', 'Var', 'DFM Form', 'Project',
    'SQL Table', 'SQL Column', 'SQL Index', 'SQL Trigger', 'SQL Generator',
    'SQL View', 'SQL Procedure', 'SQL Exception', 'SQL Domain', 'Other'
  );
var
  Present: array[TGraphNodeKind] of Boolean;
  I: Integer;
  PN: TProjNode;
  N: PGraphNode;
  K: TGraphNodeKind;
  X, Y, Count: Integer;
  NS: TNodeStyle;
  Name: string;
  LineH: Integer;
begin
  if not FShowLegend then Exit;
  if FVM = nil then Exit;

  FillChar(Present, SizeOf(Present), 0);
  for I := 0 to High(AProj.Nodes) do
  begin
    PN := AProj.Nodes[I];
    N  := FVM.Data.NodeAt(PN.NodeIdx);
    Present[N.Kind] := True;
  end;

  Count := 0;
  for K := Low(TGraphNodeKind) to High(TGraphNodeKind) do
    if Present[K] then Inc(Count);
  if Count = 0 then Exit;

  Canvas.Font.Size  := 7;
  LineH := Canvas.TextHeight('A') + 4;
  X := LEGEND_MARGIN;
  Y := LEGEND_MARGIN;

  { background box }
  Canvas.Brush.Color := TColor($00383838);
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Color   := TColor($00606060);
  Canvas.Pen.Style   := psSolid;
  Canvas.Pen.Width   := 1;
  Canvas.Rectangle(X, Y,
    X + LEGEND_SWATCH + 80 + LEGEND_MARGIN,
    Y + Count * LineH + LEGEND_MARGIN);

  X := X + LEGEND_MARGIN div 2;
  Y := Y + LEGEND_MARGIN div 2;

  for K := Low(TGraphNodeKind) to High(TGraphNodeKind) do
  begin
    if not Present[K] then Continue;
    NS   := NodeStyleFor(K);
    Name := KIND_NAMES[K];
    { swatch }
    Canvas.Brush.Color := TColor(NS.Fill);
    Canvas.Brush.Style := bsSolid;
    Canvas.Pen.Color   := TColor($00606060);
    Canvas.Rectangle(X, Y + 2, X + LEGEND_SWATCH, Y + 2 + LEGEND_SWATCH - 4);
    { name }
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Color  := CL_LABEL;
    Canvas.TextOut(X + LEGEND_SWATCH + 4, Y, Name);
    Inc(Y, LineH);
  end;
end;

{ ---------------------------------------------------------------------------- }

procedure TDragLintGraphControl.Paint;
var
  S:    string;
  Proj: TGraphProjection;
begin
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);

  if (FVM = nil) or (FVM.Data.NodeCount = 0) then
  begin
    Canvas.Font.Color  := CL_LABEL;
    Canvas.Brush.Style := bsClear;
    S := '(bind a ViewModel to display the graph)';
    Canvas.TextOut((Width  - Canvas.TextWidth(S))  div 2,
                   (Height - Canvas.TextHeight(S)) div 2, S);
    Exit;
  end;

  { Use the cached projection -- rebuilds only when FProjValid = False }
  Proj := CurrentProjection;

  DrawEdges(Proj);
  DrawNodes(Proj);
  if FShowLegend then
    DrawLegend(Proj);
end;

{ ---------------------------------------------------------------------------- }

procedure TDragLintGraphControl.MouseDown(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Proj: TGraphProjection;
  EIdx: Integer;
  N:    PGraphNode;
  PE:   TProjEdge;
  NB:   PGraphNode;
begin
  inherited;
  HideHoverHint;
  if Button = mbRight then
  begin
    SetFocus;
    if FVM = nil then Exit;
    { Right-drag pans the canvas; a right-click without dragging opens the
      context menu (decided in MouseUp). }
    FDragging    := True;
    FRightMoved  := False;
    FPanButton   := mbRight;
    FDragStartPt := Point(X, Y);
    FDragStartOX := FOffsetX;
    FDragStartOY := FOffsetY;
    Exit;
  end;
  if Button <> mbLeft then Exit;
  SetFocus;
  if FVM = nil then Exit;

  { Left-press on a node: defer the action to MouseUp so a drag (move the node)
    and a click (select/open) can be distinguished.  Capture the grab offset so
    the node tracks the cursor without jumping. }
  FDragNodeIdx := MovableNodeAt(X, Y);
  if FDragNodeIdx >= 0 then
  begin
    N := FVM.Data.NodeAt(FDragNodeIdx);
    FNodeMoved := False;
    FDownPt    := Point(X, Y);
    FDownShift := Shift;
    var W := ScreenToWorld(X, Y);
    FGrabDX := N.X - W.X;
    FGrabDY := N.Y - W.Y;
    Exit;
  end;

  { Not on a node: edge walk-select, else begin a canvas pan. }
  Proj := CurrentProjection;
  EIdx := HitTestProjEdge(X, Y, Proj);
  if EIdx >= 0 then
  begin
    PE := Proj.Edges[EIdx];
    { Walk along the link: select the endpoint that is NOT already selected, so
      after clicking O1 you can click its links to hop to each connected object.
      With no relevant selection, fall back to the target (the arrow head). }
    if FVM.SelectedId = FVM.Data.NodeAt(PE.SourceIdx).Id then
      NB := FVM.Data.NodeAt(PE.TargetIdx)
    else if FVM.SelectedId = FVM.Data.NodeAt(PE.TargetIdx).Id then
      NB := FVM.Data.NodeAt(PE.SourceIdx)
    else
      NB := FVM.Data.NodeAt(PE.TargetIdx);

    if NB.IsExternal and Assigned(FOnCrossDbJump) then
      FOnCrossDbJump(Self, NB.Label_)
    else
    begin
      FVM.SelectNode(NB.Id);
      Invalidate;
      if Assigned(FOnSelectionChange) then FOnSelectionChange(Self);
    end;
    Exit;
  end;

  { Empty space (left): arm a canvas pan.  If the press turns into a drag we
    pan (MouseMove); if it stays put it is a click that clears the selection
    (decided in MouseUp).  Left-drag panning is the intuitive gesture users
    reach for; right-drag still pans too. }
  FDragging    := True;
  FRightMoved  := False;
  FPanButton   := mbLeft;
  FDragStartPt := Point(X, Y);
  FDragStartOX := FOffsetX;
  FDragStartOY := FOffsetY;
end;

{ The left-click action, run from MouseUp when the press was not a drag.
  Box row -> member, box title -> type, else circle-node click. }
procedure TDragLintGraphControl.DoLeftClickAt(SX, SY: Integer;
  AShift: TShiftState);
var
  Proj: TGraphProjection;
  NIdx: Integer;
  N:    PGraphNode;
  Args: TGraphNodeEventArgs;
  HasChildren: Boolean;
begin
  if FVM = nil then Exit;
  if HandleUmlBoxClick(SX, SY) then Exit;

  Proj := CurrentProjection;
  NIdx := HitTestProjNode(SX, SY, Proj);
  if NIdx < 0 then Exit;

  N := FVM.Data.NodeAt(Proj.Nodes[NIdx].NodeIdx);
  HasChildren := Length(FVM.Data.ChildrenOf(Proj.Nodes[NIdx].NodeIdx)) > 0;

  FVM.SelectNode(N.Id);
  Invalidate;
  if Assigned(FOnSelectionChange) then FOnSelectionChange(Self);

  if Assigned(FOnNodeClick) then
  begin
    Args.Node  := N;
    Args.Ctrl  := ssCtrl  in AShift;
    Args.Shift := ssShift in AShift;
    Args.Alt   := ssAlt   in AShift;
    FOnNodeClick(Self, Args);
  end;

  { Ctrl -> open source; Shift -> focus neighborhood; plain -> type opens
    source, unit toggles, leaf opens source. }
  if (ssCtrl in AShift) and Assigned(FOnOpenSource) then
    FOnOpenSource(Self, N)
  else if ssShift in AShift then
  begin
    FVM.SetFocus(N.Id, 1);
    FFocusActive := True;
  end
  else if (N.Kind in [nkClass, nkInterface, nkRecord]) then
  begin
    if Assigned(FOnOpenSource) then
      FOnOpenSource(Self, N);
  end
  else if HasChildren then
  begin
    { Drill INTO a container (unit): the view shows only its contents, with a
      breadcrumb + Back.  Force a fit-relayout so we "zoom into" the subtree. }
    FVM.DrillInto(N.Id);
    Relayout;
  end
  else if (not HasChildren) and Assigned(FOnOpenSource) then
    FOnOpenSource(Self, N);
end;

procedure TDragLintGraphControl.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  N: PGraphNode;
  W: TPointF;
begin
  inherited;

  { Left node-drag -- only while the left button is held. }
  if FDragNodeIdx >= 0 then
  begin
    if (not FNodeMoved) and
       (Abs(X - FDownPt.X) + Abs(Y - FDownPt.Y) > 4) then
    begin
      FNodeMoved := True;
      Cursor := crSizeAll;
      HideHoverHint;
    end;
    if FNodeMoved then
    begin
      N := FVM.Data.NodeAt(FDragNodeIdx);
      W := ScreenToWorld(X, Y);
      N.X := W.X + FGrabDX;
      N.Y := W.Y + FGrabDY;
      N.Fixed := True;
      Invalidate;
    end;
    Exit;
  end;

  { Canvas pan -- left-drag on empty space or right-drag.  Only an active drag
    (button held) puts us in move mode; release ends it (MouseUp). }
  if FDragging then
  begin
    if (not FRightMoved) and
       (Abs(X - FDragStartPt.X) + Abs(Y - FDragStartPt.Y) > 4) then
    begin
      FRightMoved := True;
      Cursor := crSizeAll;
      HideHoverHint;
    end;
    FOffsetX := FDragStartOX - (X - FDragStartPt.X) / FZoom;
    FOffsetY := FDragStartOY - (Y - FDragStartPt.Y) / FZoom;
    Invalidate;
    Exit;
  end;

  { Button up = a plain pointer.  Do NOT change the cursor here (no hand, no
    move) and do NOT repaint -- that toggling was the flicker / "always in move
    mode" feel.  Only re-arm the dwell hint on real movement (>4px) so a
    settled mouse pops one hint and a jittering mouse does not flicker it. }
  if (Abs(X - FHoverPt.X) + Abs(Y - FHoverPt.Y) > 4) then
  begin
    HideHoverHint;
    FHoverPt := Point(X, Y);
    FHoverTimer.Enabled := False;
    FHoverTimer.Enabled := True;
  end;
end;

procedure TDragLintGraphControl.MouseUp(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  { Always leave move mode on release. }
  Cursor := crDefault;

  if Button = mbRight then
  begin
    { A right press that did not turn into a pan is a context-menu click. }
    if FDragging and (not FRightMoved) then
      ShowContextMenu(FDragStartPt.X, FDragStartPt.Y);
    FDragging   := False;
    FRightMoved := False;
    Exit;
  end;

  if Button <> mbLeft then Exit;

  if FDragNodeIdx >= 0 then
  begin
    if not FNodeMoved then
      DoLeftClickAt(X, Y, FDownShift);  { a click, not a drag }
    FDragNodeIdx := -1;
    FNodeMoved   := False;
    FDragging    := False;
    Exit;
  end;

  { Left press on empty space: a drag panned (handled in MouseMove); a plain
    click clears the selection. }
  if FDragging and (FPanButton = mbLeft) and (not FRightMoved) then
  begin
    if FVM.SelectedId <> '' then
    begin
      FVM.SelectNode('');
      Invalidate;
      if Assigned(FOnSelectionChange) then FOnSelectionChange(Self);
    end;
  end;
  FDragging := False;
end;

procedure TDragLintGraphControl.HoverTick(Sender: TObject);
var
  Idx:  Integer;
  N:    PGraphNode;
  Doc:  TGraphDoc;
  Kind, Txt: string;
begin
  FHoverTimer.Enabled := False;
  if FVM = nil then Exit;
  Idx := NodeIdxAt(FHoverPt.X, FHoverPt.Y);
  if Idx < 0 then Exit;
  N := FVM.Data.NodeAt(Idx);

  case N.Kind of
    nkUnit:      Kind := 'Unit';
    nkClass:     Kind := 'Class';
    nkInterface: Kind := 'Interface';
    nkRecord:    Kind := 'Record';
    nkType:      Kind := 'Type';
    nkMethod:    Kind := 'Method';
    nkProcedure: Kind := 'Procedure';
    nkFunction:  Kind := 'Function';
    nkProperty:  Kind := 'Property';
    nkField:     Kind := 'Field';
    nkConst:     Kind := 'Const';
    nkVar:       Kind := 'Var';
    nkProject:   Kind := 'Project';
    nkDfmForm:   Kind := 'Form';
  else
    Kind := 'Symbol';
  end;

  Txt := Kind + ': ' + N.Id;
  if N.Signature <> '' then
    Txt := Txt + #13#10 + N.Signature;
  if N.Section = 'implementation' then
    Txt := Txt + #13#10 + '(implementation-only - not usable from another unit)'
  else if N.Section = 'interface' then
    Txt := Txt + #13#10 + '(interface section)';
  Doc := FVM.DocFor(N.Id);
  if Doc.HasDoc and (Doc.Summary <> '') then
    Txt := Txt + #13#10#13#10 + Doc.Summary;

  ShowHoverHint(FHoverPt, Txt);
end;

procedure TDragLintGraphControl.ShowHoverHint(const APt: TPoint;
  const AText: string);
var
  R:  TRect;
  SP: TPoint;
begin
  if AText = '' then Exit;
  if FHintWin = nil then
    FHintWin := THintWindow.Create(Self);
  R := FHintWin.CalcHintRect(420, AText, nil);
  SP := ClientToScreen(Point(APt.X + 14, APt.Y + 18));
  OffsetRect(R, SP.X, SP.Y);
  FHintWin.ActivateHint(R, AText);
end;

procedure TDragLintGraphControl.HideHoverHint;
begin
  FHoverTimer.Enabled := False;
  if (FHintWin <> nil) and FHintWin.HandleAllocated and
     IsWindowVisible(FHintWin.Handle) then
    ShowWindow(FHintWin.Handle, SW_HIDE);
end;

procedure TDragLintGraphControl.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  HideHoverHint;
  Cursor := crDefault;
end;

procedure TDragLintGraphControl.DblClick;
var
  Proj: TGraphProjection;
  NIdx: Integer;
  N:    PGraphNode;
  MP:   TPoint;
begin
  inherited;
  if FVM = nil then Exit;
  MP   := ScreenToClient(Mouse.CursorPos);
  Proj := CurrentProjection;
  NIdx := HitTestProjNode(MP.X, MP.Y, Proj);
  if NIdx < 0 then Exit;
  N := FVM.Data.NodeAt(Proj.Nodes[NIdx].NodeIdx);
  { Single-click now owns expand/collapse (F6), so double-click is the deeper
    "navigate into" gesture: expand ancestors + this node and select it.
    NavigateTo forces-expanded (not toggle), so the preceding single-click's
    MouseDown toggle never produces a visible flip-flop. }
  FVM.NavigateTo(N.Id);
end;

procedure TDragLintGraphControl.KeyDown(var Key: Word; Shift: TShiftState);
const
  VK_F = Ord('F');
begin
  inherited;
  if FVM = nil then Exit;
  case Key of
    VK_F:
      begin
        if FVM.SelectedId <> '' then
        begin
          FVM.SetFocus(FVM.SelectedId, 1);
          FFocusActive := True;
        end;
        Key := 0;
      end;
    VK_ESCAPE:
      begin
        { Esc unwinds one level at a time: first clear an active focus, then
          (if a top-level cap was expanded via "Show all") collapse back to
          the high-level view -- closing the loop the user opened (F6 note). }
        if FFocusActive then
        begin
          FVM.ClearFocus;
          FFocusActive := False;
        end
        else if FVM.ShowAllTopLevel then
          FVM.SetShowAllTopLevel(False)
        else
          FVM.ClearFocus;
        Key := 0;
      end;
    VK_BACK:
      begin
        if FVM.CanGoBack then FVM.Back;
        Key := 0;
      end;
  end;
end;

function TDragLintGraphControl.DoMouseWheel(Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  MouseWorld: TPointF;
  NewZoom:    Double;
  ZoomMul:    Double;
  Local:      TPoint;
begin
  Result := True;
  Local  := ScreenToClient(MousePos);

  { Wheel over a UML class-box scrolls its member list instead of zooming. }
  var BI: Integer;
  for BI := High(FUmlBoxes) downto 0 do
    if (Local.X >= FUmlBoxes[BI].Box.Left) and (Local.X < FUmlBoxes[BI].Box.Right) and
       (Local.Y >= FUmlBoxes[BI].Box.Top) and (Local.Y < FUmlBoxes[BI].Box.Bottom) then
    begin
      var Idx := FUmlBoxes[BI].NodeIdx;
      var Off := 0;
      FBoxScroll.TryGetValue(Idx, Off);
      if WheelDelta > 0 then Dec(Off) else Inc(Off);
      if Off < 0 then Off := 0;
      FBoxScroll.AddOrSetValue(Idx, Off);   { DrawUmlTypeBox clamps the top }
      Invalidate;
      Exit;
    end;

  MouseWorld := ScreenToWorld(Local.X, Local.Y);
  ZoomMul := IfThen(WheelDelta > 0, 1.15, 1.0 / 1.15);
  NewZoom := FZoom * ZoomMul;
  if NewZoom < 0.02 then NewZoom := 0.02;
  if NewZoom > 20.0 then NewZoom := 20.0;
  FZoom := NewZoom;
  FOffsetX := MouseWorld.X - (Local.X - Width  / 2) / FZoom;
  FOffsetY := MouseWorld.Y - (Local.Y - Height / 2) / FZoom;
  { Zoom does NOT invalidate the projection cache -- topology unchanged. }
  Invalidate;
  if Assigned(FOnZoomChanged) then FOnZoomChanged(Self);
end;

end.
