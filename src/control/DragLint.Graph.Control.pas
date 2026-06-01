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

   Simplifications documented:
     * Full-store force-directed layout runs once on Bind/StoreChanged.
       Only the visible projection nodes are drawn; visible-only relayout
       is deferred (LOD phase).
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
  System.UITypes,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.ExtCtrls,
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

  TDragLintGraphControl = class(TCustomControl)
  strict private
    FVM:     IGraphViewModel;
    FLayout: TGraphLayout;

    { View transform }
    FZoom:    Double;
    FOffsetX: Double;
    FOffsetY: Double;

    { Mouse interaction state }
    FDragging:    Boolean;
    FDragStartPt: TPoint;
    FDragStartOX: Double;
    FDragStartOY: Double;

    { Projection cache -- rebuilt only when VM state changes }
    FProjection: TGraphProjection;
    FProjValid:  Boolean;

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
    FOnOpenSource:      TGraphIdEvent;
    FOnCrossDbJump:     TGraphNameEvent;
    FOnViewChanged:     TNotifyEvent;
    FOnZoomChanged:     TNotifyEvent;

    procedure AnimTick(Sender: TObject);

    { VM event callbacks }
    procedure HandleVMChanged(Sender: TObject);
    procedure HandleVMStoreChanged(Sender: TObject);

    { Layout / view helpers }
    procedure Relayout;

    function  WorldToScreen(WX, WY: Double): TPoint;
    function  ScreenToWorld(SX, SY: Integer): TPointF;
    function  HitTestProjNode(SX, SY: Integer;
                              const AProj: TGraphProjection): Integer;
    function  HitTestProjEdge(SX, SY: Integer;
                              const AProj: TGraphProjection): Integer;

    { Returns the cached projection, rebuilding it if necessary. }
    function  CurrentProjection: TGraphProjection;

    procedure DrawEdges(const AProj: TGraphProjection);
    procedure DrawNodes(const AProj: TGraphProjection);
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
    property OnOpenSource:       TGraphIdEvent    read FOnOpenSource
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
end;

destructor TDragLintGraphControl.Destroy;
begin
  FAnimTimer.Free;
  FLayout.Free;
  inherited;
end;

{ ---------------------------------------------------------------------------- }

procedure TDragLintGraphControl.Bind(const AVM: IGraphViewModel);
begin
  FVM := AVM;
  FProjValid := False;
  if FVM <> nil then
  begin
    FVM.SetOnChanged(HandleVMChanged);
    FVM.SetOnStoreChanged(HandleVMStoreChanged);
    Relayout;
  end;
  Invalidate;
end;

procedure TDragLintGraphControl.HandleVMChanged(Sender: TObject);
begin
  FProjValid := False;
  Invalidate;
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
end;

procedure TDragLintGraphControl.HandleVMStoreChanged(Sender: TObject);
begin
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
const
  { O(N^2) per iteration: cap at a low step count for very large graphs to
    avoid a multi-minute hang.  For NodeCount > 2000 we only seed positions
    (Init) and run a handful of steps so the layout is at least partially
    placed.  Visible-only relayout is a deferred LOD improvement. }
  LAYOUT_LARGE_THRESHOLD = 2000;
  LAYOUT_LARGE_STEPS     = 5;
  LAYOUT_NORMAL_STEPS    = 200;
var
  Steps: Integer;
begin
  if (FVM = nil) or (FVM.Data = nil) then Exit;
  if FVM.Data.NodeCount = 0 then Exit;
  FLayout.Init(FVM.Data, Width * 2.0, Height * 2.0);
  if FVM.Data.NodeCount > LAYOUT_LARGE_THRESHOLD then
    Steps := LAYOUT_LARGE_STEPS
  else
    Steps := LAYOUT_NORMAL_STEPS;
  FLayout.Step(FVM.Data, Steps);
  FitToWindow;
end;

procedure TDragLintGraphControl.AnimTick(Sender: TObject);
var
  Done: Boolean;
begin
  if FVM = nil then Exit;
  Done := FLayout.Step(FVM.Data, 1);
  { layout moved nodes -> world coords changed -> projection must rebuild }
  FProjValid := False;
  Invalidate;
  if Done then FAnimTimer.Enabled := False;
end;

{ ---------------------------------------------------------------------------- }

procedure TDragLintGraphControl.FitToWindow;
var
  MinX, MaxX, MinY, MaxY: Double;
  I: Integer;
  N: PGraphNode;
  SpanX, SpanY: Double;
  ZoomX, ZoomY: Double;
begin
  if (FVM = nil) or (FVM.Data.NodeCount = 0) then
  begin
    FZoom := 1.0; FOffsetX := 0; FOffsetY := 0;
    Invalidate;
    if Assigned(FOnZoomChanged) then FOnZoomChanged(Self);
    Exit;
  end;
  MinX :=  1.0E30; MaxX := -1.0E30;
  MinY :=  1.0E30; MaxY := -1.0E30;
  for I := 0 to FVM.Data.NodeCount - 1 do
  begin
    N := FVM.Data.NodeAt(I);
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
  I:        Integer;
  PN:       TProjNode;
  N:        PGraphNode;
  P:        TPoint;
  DX, DY:   Integer;
  RadiusPx: Integer;
begin
  Result := -1;
  if FVM = nil then Exit;
  for I := High(AProj.Nodes) downto 0 do
  begin
    PN := AProj.Nodes[I];
    N  := FVM.Data.NodeAt(PN.NodeIdx);
    P  := WorldToScreen(N.X, N.Y);
    DX := SX - P.X;
    DY := SY - P.Y;
    RadiusPx := Round(N.Radius * FZoom);
    if RadiusPx < 4 then RadiusPx := 4;
    if (DX * DX + DY * DY) <= (RadiusPx * RadiusPx) then
    begin
      Result := I;
      Exit;
    end;
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
  { tip is 8px back from PB }
  AX := PB.X - Round(UX * 8);
  AY := PB.Y - Round(UY * 8);
  { left/right wing 5px perpendicular, 8px back from tip }
  LX := AX - Round(UX * 8) + Round(UY * 5);
  LY := AY - Round(UY * 8) - Round(UX * 5);
  RX := AX - Round(UX * 8) - Round(UY * 5);
  RY := AY - Round(UY * 8) + Round(UX * 5);
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

  for I := 0 to High(AProj.Nodes) do
  begin
    PN := AProj.Nodes[I];
    N  := FVM.Data.NodeAt(PN.NodeIdx);
    P  := WorldToScreen(N.X, N.Y);
    R  := Round(N.Radius * FZoom);
    if R < 4 then R := 4;

    NS := NodeStyleFor(N.Kind);
    FillCol := TColor(NS.Fill);

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

    { Draw shape }
    case NS.Shape of
      nsEllipse:
        Canvas.Ellipse(P.X - R, P.Y - R, P.X + R, P.Y + R);
      nsBox:
        Canvas.Rectangle(P.X - NODE_W div 2, P.Y - NODE_H div 2,
                          P.X + NODE_W div 2, P.Y + NODE_H div 2);
      nsRoundBox:
        Canvas.RoundRect(P.X - NODE_W div 2, P.Y - NODE_H div 2,
                          P.X + NODE_W div 2, P.Y + NODE_H div 2,
                          6, 6);
    else
      { nsDiamond, nsHexagon, nsCylinder, nsTag, nsTriangle: box fallback }
      Canvas.Rectangle(P.X - NODE_W div 2, P.Y - NODE_H div 2,
                        P.X + NODE_W div 2, P.Y + NODE_H div 2);
    end;

    Canvas.Pen.Style  := psSolid;
    Canvas.Pen.Width  := 1;

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

    { Label: always drawn for the selected node; zoom-gated for others. }
    if (FZoom >= 0.6) or (N.Id = SelId) then
    begin
      S := N.Label_;
      if S = '' then S := N.Id;
      if PN.Collapsed then
      begin
        DescN := FVM.Data.DescendantCount(PN.NodeIdx);
        S := S + ' (+' + IntToStr(DescN) + ')';
      end;
      if (N.Id = SelId) and (FZoom < 0.6) then
      begin
        { Selected node at low zoom: draw a readable background behind label }
        Canvas.Font.Size  := 8;
        Canvas.Font.Color := CL_LABEL;
        Canvas.Brush.Color := TColor($00303060);
        Canvas.Brush.Style := bsSolid;
        Canvas.Pen.Color   := CL_SEL_BORDER;
        Canvas.Pen.Width   := 1;
        Canvas.Pen.Style   := psSolid;
        Canvas.Rectangle(
          P.X - Canvas.TextWidth(S) div 2 - 2, P.Y + R + 1,
          P.X + Canvas.TextWidth(S) div 2 + 2, P.Y + R + Canvas.TextHeight(S) + 3);
        Canvas.Brush.Style := bsClear;
        Canvas.TextOut(P.X - Canvas.TextWidth(S) div 2, P.Y + R + 2, S);
      end
      else
      begin
        Canvas.Brush.Style := bsClear;
        Canvas.Font.Color  := CL_LABEL;
        Canvas.Font.Size   := 8;
        Canvas.TextOut(P.X - Canvas.TextWidth(S) div 2, P.Y + R + 2, S);
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
  Proj:    TGraphProjection;
  NIdx:    Integer;
  EIdx:    Integer;
  N:       PGraphNode;
  PE:      TProjEdge;
  NB:      PGraphNode;
  Args:    TGraphNodeEventArgs;
  HasChildren: Boolean;
begin
  inherited;
  if Button <> mbLeft then Exit;
  SetFocus;
  if FVM = nil then Exit;

  { Use cached projection for hit-testing; no topology change here. }
  Proj := CurrentProjection;
  NIdx := HitTestProjNode(X, Y, Proj);
  if NIdx >= 0 then
  begin
    N := FVM.Data.NodeAt(Proj.Nodes[NIdx].NodeIdx);
    HasChildren := Length(FVM.Data.ChildrenOf(Proj.Nodes[NIdx].NodeIdx)) > 0;

    FVM.SelectNode(N.Id);
    { Selection changes the border color but not topology: Invalidate only,
      do NOT invalidate the cached projection. }
    Invalidate;
    if Assigned(FOnSelectionChange) then FOnSelectionChange(Self);

    { Host hook (status bar / custom handling) fires first so that the
      primary action below -- which may set its own status (e.g. "Opened:")
      -- has the last word. }
    if Assigned(FOnNodeClick) then
    begin
      Args.Node  := N;
      Args.Ctrl  := ssCtrl  in Shift;
      Args.Shift := ssShift in Shift;
      Args.Alt   := ssAlt   in Shift;
      FOnNodeClick(Self, Args);
    end;

    { Primary single-click action.  Modifiers take precedence; plain click
      is the discoverable path (F6/F7):
        Ctrl  -> open source, on ANY node (power override)
        Shift -> focus this node's neighborhood (1 hop)
        plain -> container expands/collapses (F6); leaf opens source (F7) }
    if (ssCtrl in Shift) and Assigned(FOnOpenSource) then
      FOnOpenSource(Self, N.Id)
    else if ssShift in Shift then
    begin
      FVM.SetFocus(N.Id, 1);
      FFocusActive := True;
    end
    else if FExpandOnSingleClick and HasChildren then
      FVM.ToggleCollapse(N.Id)
    else if (not HasChildren) and Assigned(FOnOpenSource) then
      FOnOpenSource(Self, N.Id);
    Exit;
  end;

  { edge hit-test }
  EIdx := HitTestProjEdge(X, Y, Proj);
  if EIdx >= 0 then
  begin
    PE := Proj.Edges[EIdx];
    NB := FVM.Data.NodeAt(PE.TargetIdx);
    if NB.IsExternal and Assigned(FOnCrossDbJump) then
      FOnCrossDbJump(Self, NB.Label_)
    else
      FVM.NavigateTo(NB.Id);
    Exit;
  end;

  { empty space -> begin pan }
  FDragging    := True;
  FDragStartPt := Point(X, Y);
  FDragStartOX := FOffsetX;
  FDragStartOY := FOffsetY;
end;

{ MouseMove only handles pan.  Hover hit-testing and hover-driven Invalidate
  have been removed (bug F1): moving the mouse over the canvas causes NO
  repaint unless a drag (pan) is in progress. }
procedure TDragLintGraphControl.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FDragging then
  begin
    FOffsetX := FDragStartOX - (X - FDragStartPt.X) / FZoom;
    FOffsetY := FDragStartOY - (Y - FDragStartPt.Y) / FZoom;
    { Pan does NOT invalidate the projection cache -- topology unchanged. }
    Invalidate;
  end;
  { No hover hit-test, no Invalidate when not dragging. }
end;

procedure TDragLintGraphControl.MouseUp(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
    FDragging := False;
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
