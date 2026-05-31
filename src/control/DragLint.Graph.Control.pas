unit DragLint.Graph.Control;

(* TDragLintGraphControl: pure VCL interactive graph viewer.

   Coordinate model:
     Logical "world" coordinates live in TGraphNode.X/.Y as floats centered
     around (0, 0). The on-screen pixel position is computed via:
        sx = (X - FOffsetX) * FZoom + ClientWidth  / 2
        sy = (Y - FOffsetY) * FZoom + ClientHeight / 2
     Pan = mutating FOffsetX/Y. Zoom = mutating FZoom around mouse anchor.

   Events:
     OnNodeClick(Sender, Args)  - Args.Node = nil safe to ignore
     OnNodeHover(Sender, Node)  - Node = nil on leave
     OnSelectionChange(Sender)

   Rendering:
     Edges first (so nodes paint over), then node circles, then labels.
     No transparent compositing tricks; VCL Canvas is enough for 5k nodes.

   Layout:
     Runs synchronously on data load (Init + 200 iters). For large graphs
     we would move this to a TThread; phase-1 keeps it simple. *)

interface

uses
  System.SysUtils, System.Classes, System.Types, System.Math,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.ExtCtrls,
  Winapi.Windows, Winapi.Messages,
  DragLint.Graph.Types,
  DragLint.Graph.Layout;

type
  TGraphNodeEventArgs = record
    Node:   PGraphNode;
    Ctrl:   Boolean;
    Shift:  Boolean;
    Alt:    Boolean;
  end;

  TGraphNodeEvent     = procedure(Sender: TObject; const A: TGraphNodeEventArgs) of object;
  TGraphHoverEvent    = procedure(Sender: TObject; ANode: PGraphNode) of object;

  TDragLintGraphControl = class(TCustomControl)
  strict private
    FData:    TGraphData;
    FLayout:  TGraphLayout;
    FOwnsData: Boolean;

    { View transform }
    FZoom:    Double;
    FOffsetX: Double;
    FOffsetY: Double;

    { Mouse interaction state }
    FDragging:    Boolean;
    FDragStartPt: TPoint;
    FDragStartOX: Double;
    FDragStartOY: Double;
    FHoverNode:   PGraphNode;
    FSelectedId:  string;

    { Optional background relayout via TTimer (phase-1 simple) }
    FAnimTimer:   TTimer;

    FOnNodeClick: TGraphNodeEvent;
    FOnNodeHover: TGraphHoverEvent;
    FOnSelectionChange: TNotifyEvent;

    procedure AnimTick(Sender: TObject);
    procedure DoNodeClick(ANode: PGraphNode; ACtrl, AShift, AAlt: Boolean);

    function WorldToScreen(WX, WY: Double): TPoint;
    function ScreenToWorld(SX, SY: Integer): TPointF;
    function HitTestNode(SX, SY: Integer): PGraphNode;

    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Load a graph. If AOwnsData is True, control frees AData on destroy /
      next LoadData. Otherwise caller retains ownership. }
    procedure LoadData(AData: TGraphData; AOwnsData: Boolean = True);

    { Run AIterations of force-directed layout (synchronous). }
    procedure RunLayout(AIterations: Integer = 200);

    procedure FitToWindow;
    procedure SelectNode(const AId: string);

    property Data: TGraphData read FData;
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

    property OnClick;
    property OnNodeClick: TGraphNodeEvent      read FOnNodeClick      write FOnNodeClick;
    property OnNodeHover: TGraphHoverEvent     read FOnNodeHover      write FOnNodeHover;
    property OnSelectionChange: TNotifyEvent   read FOnSelectionChange write FOnSelectionChange;
  end;

implementation

const
  { Phase-1 palette. Phase-3 will read these from TStyleManager. }
  CL_BG       = TColor($00282828);
  CL_NODE     = TColor($00C4A484);
  CL_NODE_SEL = TColor($000080FF);
  CL_NODE_HOV = TColor($0066D9EF);
  CL_EDGE     = TColor($00606060);
  CL_LABEL    = TColor($00E0E0E0);

constructor TDragLintGraphControl.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle := ControlStyle + [csOpaque, csClickEvents, csCaptureMouse];
  Width  := 600;
  Height := 400;
  TabStop := True;
  Color := CL_BG;

  FData    := nil;
  FLayout  := TGraphLayout.Create;
  FOwnsData := False;

  FZoom    := 1.0;
  FOffsetX := 0;
  FOffsetY := 0;

  FAnimTimer := TTimer.Create(Self);
  FAnimTimer.Enabled := False;
  FAnimTimer.Interval := 33;  { ~30 fps }
  FAnimTimer.OnTimer := AnimTick;
end;

destructor TDragLintGraphControl.Destroy;
begin
  FAnimTimer.Free;
  FLayout.Free;
  if FOwnsData then FreeAndNil(FData);
  inherited;
end;

procedure TDragLintGraphControl.LoadData(AData: TGraphData; AOwnsData: Boolean);
begin
  if FOwnsData and (FData <> nil) and (FData <> AData) then
    FreeAndNil(FData);
  FData := AData;
  FOwnsData := AOwnsData;
  FHoverNode := nil;
  FSelectedId := '';
  if FData <> nil then
  begin
    FLayout.Init(FData, Width * 2.0, Height * 2.0);
    RunLayout(200);
    FitToWindow;
  end;
  Invalidate;
end;

procedure TDragLintGraphControl.RunLayout(AIterations: Integer);
begin
  if FData = nil then Exit;
  FLayout.Step(FData, AIterations);
  Invalidate;
end;

procedure TDragLintGraphControl.AnimTick(Sender: TObject);
var
  Done: Boolean;
begin
  if FData = nil then Exit;
  Done := FLayout.Step(FData, 1);
  Invalidate;
  if Done then FAnimTimer.Enabled := False;
end;

procedure TDragLintGraphControl.FitToWindow;
var
  MinX, MaxX, MinY, MaxY: Double;
  I: Integer;
  N: PGraphNode;
  SpanX, SpanY: Double;
  ZoomX, ZoomY: Double;
begin
  if (FData = nil) or (FData.NodeCount = 0) then
  begin
    FZoom := 1.0;
    FOffsetX := 0;
    FOffsetY := 0;
    Invalidate;
    Exit;
  end;
  MinX :=  1.0E30; MaxX := -1.0E30;
  MinY :=  1.0E30; MaxY := -1.0E30;
  for I := 0 to FData.NodeCount - 1 do
  begin
    N := FData.NodeAt(I);
    if N.X < MinX then MinX := N.X;
    if N.X > MaxX then MaxX := N.X;
    if N.Y < MinY then MinY := N.Y;
    if N.Y > MaxY then MaxY := N.Y;
  end;
  SpanX := MaxX - MinX;
  SpanY := MaxY - MinY;
  if SpanX < 1 then SpanX := 1;
  if SpanY < 1 then SpanY := 1;
  ZoomX := (Width  - 40) / SpanX;
  ZoomY := (Height - 40) / SpanY;
  FZoom := Min(ZoomX, ZoomY);
  if FZoom > 2.0 then FZoom := 2.0;
  if FZoom < 0.1 then FZoom := 0.1;
  FOffsetX := (MinX + MaxX) / 2;
  FOffsetY := (MinY + MaxY) / 2;
  Invalidate;
end;

procedure TDragLintGraphControl.SelectNode(const AId: string);
var
  Idx: Integer;
  I:   Integer;
  N:   PGraphNode;
begin
  if FData = nil then Exit;
  Idx := FData.FindNodeIndex(AId);
  for I := 0 to FData.NodeCount - 1 do
  begin
    N := FData.NodeAt(I);
    N.Selected := (I = Idx);
  end;
  if Idx >= 0 then FSelectedId := AId else FSelectedId := '';
  if Assigned(FOnSelectionChange) then FOnSelectionChange(Self);
  Invalidate;
end;

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

function TDragLintGraphControl.HitTestNode(SX, SY: Integer): PGraphNode;
var
  I:        Integer;
  N:        PGraphNode;
  P:        TPoint;
  DX, DY:   Integer;
  RadiusPx: Integer;
begin
  Result := nil;
  if FData = nil then Exit;
  for I := FData.NodeCount - 1 downto 0 do
  begin
    N := FData.NodeAt(I);
    P := WorldToScreen(N.X, N.Y);
    DX := SX - P.X;
    DY := SY - P.Y;
    RadiusPx := Round(N.Radius * FZoom);
    if RadiusPx < 4 then RadiusPx := 4;
    if (DX * DX + DY * DY) <= (RadiusPx * RadiusPx) then
    begin
      Result := N;
      Exit;
    end;
  end;
end;

procedure TDragLintGraphControl.Paint;
var
  I:       Integer;
  N, A, B: PGraphNode;
  E:       TGraphEdge;
  PA, PB:  TPoint;
  R:       Integer;
  S:       string;
  TextH:   Integer;
begin
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);
  if (FData = nil) or (FData.NodeCount = 0) then
  begin
    Canvas.Font.Color := CL_LABEL;
    Canvas.Brush.Style := bsClear;
    S := '(no graph data loaded)';
    Canvas.TextOut((Width - Canvas.TextWidth(S)) div 2,
                   (Height - Canvas.TextHeight(S)) div 2, S);
    Exit;
  end;

  { Edges }
  Canvas.Pen.Color := CL_EDGE;
  Canvas.Pen.Width := 1;
  for I := 0 to FData.EdgeCount - 1 do
  begin
    E := FData.EdgeAt(I);
    A := FData.FindNode(E.SourceId);
    B := FData.FindNode(E.TargetId);
    if (A = nil) or (B = nil) then Continue;
    PA := WorldToScreen(A.X, A.Y);
    PB := WorldToScreen(B.X, B.Y);
    Canvas.MoveTo(PA.X, PA.Y);
    Canvas.LineTo(PB.X, PB.Y);
  end;

  { Nodes }
  Canvas.Pen.Color := CL_BG;
  Canvas.Pen.Width := 1;
  for I := 0 to FData.NodeCount - 1 do
  begin
    N := FData.NodeAt(I);
    PA := WorldToScreen(N.X, N.Y);
    R := Round(N.Radius * FZoom);
    if R < 4 then R := 4;

    if N.Selected then
      Canvas.Brush.Color := CL_NODE_SEL
    else if N.Hovered then
      Canvas.Brush.Color := CL_NODE_HOV
    else
      Canvas.Brush.Color := CL_NODE;

    Canvas.Ellipse(PA.X - R, PA.Y - R, PA.X + R, PA.Y + R);
  end;

  { Labels — only at sufficient zoom to keep readable }
  if FZoom >= 0.6 then
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Color := CL_LABEL;
    Canvas.Font.Size := 8;
    TextH := Canvas.TextHeight('A');
    for I := 0 to FData.NodeCount - 1 do
    begin
      N := FData.NodeAt(I);
      PA := WorldToScreen(N.X, N.Y);
      R := Round(N.Radius * FZoom);
      if R < 4 then R := 4;
      S := N.Label_;
      if S = '' then S := N.Id;
      Canvas.TextOut(PA.X - Canvas.TextWidth(S) div 2,
                     PA.Y + R + 2, S);
      if N.Hovered then
        Canvas.TextOut(PA.X + R + 4, PA.Y - TextH div 2, N.FilePath);
    end;
  end;
end;

procedure TDragLintGraphControl.MouseDown(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  N: PGraphNode;
begin
  inherited;
  if Button = mbLeft then
  begin
    SetFocus;
    N := HitTestNode(X, Y);
    if N <> nil then
    begin
      SelectNode(N.Id);
      DoNodeClick(N, ssCtrl in Shift, ssShift in Shift, ssAlt in Shift);
    end
    else
    begin
      FDragging    := True;
      FDragStartPt := Point(X, Y);
      FDragStartOX := FOffsetX;
      FDragStartOY := FOffsetY;
    end;
  end;
end;

procedure TDragLintGraphControl.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  N: PGraphNode;
begin
  inherited;
  if FDragging then
  begin
    FOffsetX := FDragStartOX - (X - FDragStartPt.X) / FZoom;
    FOffsetY := FDragStartOY - (Y - FDragStartPt.Y) / FZoom;
    Invalidate;
    Exit;
  end;

  N := HitTestNode(X, Y);
  if N <> FHoverNode then
  begin
    if FHoverNode <> nil then FHoverNode.Hovered := False;
    FHoverNode := N;
    if N <> nil then N.Hovered := True;
    if Assigned(FOnNodeHover) then FOnNodeHover(Self, N);
    Invalidate;
  end;
end;

procedure TDragLintGraphControl.MouseUp(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
    FDragging := False;
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
  Local := ScreenToClient(MousePos);
  MouseWorld := ScreenToWorld(Local.X, Local.Y);
  if WheelDelta > 0 then
    ZoomMul := 1.15
  else
    ZoomMul := 1.0 / 1.15;
  NewZoom := FZoom * ZoomMul;
  if NewZoom < 0.05 then NewZoom := 0.05;
  if NewZoom > 20.0 then NewZoom := 20.0;
  FZoom := NewZoom;
  { Reanchor so the point under the cursor stays stable }
  FOffsetX := MouseWorld.X - (Local.X - Width  / 2) / FZoom;
  FOffsetY := MouseWorld.Y - (Local.Y - Height / 2) / FZoom;
  Invalidate;
end;

procedure TDragLintGraphControl.CMMouseLeave(var Msg: TMessage);
begin
  if FHoverNode <> nil then
  begin
    FHoverNode.Hovered := False;
    FHoverNode := nil;
    if Assigned(FOnNodeHover) then FOnNodeHover(Self, nil);
    Invalidate;
  end;
end;

procedure TDragLintGraphControl.DoNodeClick(ANode: PGraphNode;
  ACtrl, AShift, AAlt: Boolean);
var
  A: TGraphNodeEventArgs;
begin
  if not Assigned(FOnNodeClick) then Exit;
  A.Node := ANode;
  A.Ctrl := ACtrl;
  A.Shift := AShift;
  A.Alt := AAlt;
  FOnNodeClick(Self, A);
end;

end.
