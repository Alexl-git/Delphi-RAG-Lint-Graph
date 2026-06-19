unit DragLint.Graph.FlowControl;

{ Vertical-flowchart renderer for a TFlowViewModel. A TScrollBox host with an
  inner TPaintBox sized to the laid-out content; paints stacked detail-boxes
  joined by connectors, hit-tests clicks for select / per-box expand toggle.

  Text is ASCII only ('->' not arrows). CRLF line endings. }

interface

uses
  System.SysUtils
  , System.Classes
  , System.Types
  , System.UITypes
  , System.Generics.Collections
  , Vcl.Controls
  , Vcl.Graphics
  , Vcl.Forms
  , Vcl.ExtCtrls
  , DragLint.Graph.Types
  , DragLint.Graph.Flow
  , DragLint.Graph.Flow.ViewModel
  ;

type
  /// <summary>Callback raised when the user clicks a resolved flow box; ASymbolId is the qualified name.</summary>
  TFlowSymbolEvent = procedure(Sender: TObject; const ASymbolId: string) of object;

  /// <summary>Renders a TFlowViewModel as a scrollable vertical flowchart and
  ///  reports box selection via OnSelectSymbol.</summary>
  TFlowChartControl = class(TScrollBox)
    strict private
      FPaint      : TPaintBox       ;
      FVM         : TFlowViewModel  ;
      FBoxRects   : TList<TRect>    ; { index-aligned with VM.Tree.Steps }
      FToggleRects: TList<TRect>    ; { per-step +/- hit rect }
      FMoreRects  : TList<TRect>    ; { per-step "... N more" hit rect }
      FContentH   : Integer         ;
      FOnSelect   : TFlowSymbolEvent;
      FMeasure    : TBitmap         ; { offscreen canvas for word-wrap measuring }
      procedure PaintBoxPaint(Sender: TObject);
      procedure PaintBoxMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
      procedure VMChanged(Sender: TObject);
      function WrapLine(const S: string; ABold: Boolean): TArray<string>;
      function BoxLines(AIndex: Integer): TArray<string>;
      procedure Relayout;
    public
      /// <summary>Creates the control and its inner TPaintBox; call Attach before use.</summary>
      constructor Create(AOwner: TComponent); override;
      /// <summary>Detaches from the VM and frees layout lists.</summary>
      destructor Destroy; override;
      /// <summary>Binds this control to AVM; replaces any previous binding.</summary>
      procedure Attach(AVM: TFlowViewModel);
      /// <summary>Fired when the user selects a resolved flow box (not external).</summary>
      property OnSelectSymbol: TFlowSymbolEvent read FOnSelect write FOnSelect;
      /// <summary>One-line self-diagnostic: box count + widest wrapped line vs the
      ///  box text width + how many lines overflow (0 = wrapping OK). For --selftest.</summary>
      function DiagDump: string;
  end;

implementation

const
  BOX_W       = 360;
  BOX_PAD     = 8;
  LINE_H      = 16;
  V_GAP       = 28; { vertical gap between boxes (room for connector) }
  INDENT      = 24; { px per depth level }
  LEFT_MARGIN = 16;
  TOP_MARGIN  = 12;
  TOGGLE_SZ   = 14;

constructor TFlowChartControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FBoxRects   := TList<TRect>.Create;
  FToggleRects:= TList<TRect>.Create;
  FMoreRects  := TList<TRect>.Create;
  FMeasure    := TBitmap.Create;
  FMeasure.SetSize(8, 8);            { a real DC so TextWidth works outside paint }
  FMeasure.Canvas.Font.Assign(Font);
  BorderStyle:= bsNone;
  Color      := clWindow;
  FPaint:= TPaintBox.Create(Self);
  FPaint.Parent     := Self;
  FPaint.OnPaint    := PaintBoxPaint;
  FPaint.OnMouseDown:= PaintBoxMouseDown;
end;

destructor TFlowChartControl.Destroy;
begin
  { Detach from the VM so a VM that outlives this control never calls back
    into a freed instance (the VM may be owned elsewhere). }
  if FVM <> nil then FVM.OnChanged:= nil;
  FMeasure.Free;
  FMoreRects.Free;
  FToggleRects.Free;
  FBoxRects.Free;
  inherited;
end;

procedure TFlowChartControl.Attach(AVM: TFlowViewModel);
begin
  { Drop our handler from any previously-attached VM before switching. }
  if FVM <> nil then FVM.OnChanged:= nil;
  FVM:= AVM;
  if FVM <> nil then FVM.OnChanged:= VMChanged;
  Relayout;
  FPaint.Invalidate;
end;

procedure TFlowChartControl.VMChanged(Sender: TObject);
begin
  Relayout;
  FPaint.Invalidate;
end;

function TFlowChartControl.WrapLine(const S: string; ABold: Boolean): TArray<string>;
{ Greedy word-wrap of S to the box text width, so long signatures/summaries no
  longer overflow the box. Measures on the offscreen FMeasure canvas (the
  TPaintBox canvas is only valid during OnPaint). A single over-long word is
  hard-broken. The head line is measured bold (it is painted bold). }
const
  MAX_PX = BOX_W - 2 * BOX_PAD;
var
  Cv   : TCanvas      ;
  Words: TArray<string>;
  Cur  : string       ;
  Test : string       ;
  Cut  : Integer      ;
  I    : Integer      ;
  L    : TList<string>;
begin
  Cv:= FMeasure.Canvas;
  if ABold then Cv.Font.Style:= [fsBold] else Cv.Font.Style:= [];
  if (S = '') or (Cv.TextWidth(S) <= MAX_PX) then
  begin
    SetLength(Result, 1); Result[0]:= S; Exit;
  end;
  L:= TList<string>.Create;
  try
    Words:= S.Split([' ']);
    Cur:= '';
    for I:= 0 to High(Words) do
    begin
      if Cur = '' then Test:= Words[I] else Test:= Cur + ' ' + Words[I];
      if Cv.TextWidth(Test) <= MAX_PX then Cur:= Test
      else
      begin
        if Cur <> '' then begin L.Add(Cur); Cur:= ''; end;
        { a single word wider than the box -> hard-break it across lines }
        Cur:= Words[I];
        while Cv.TextWidth(Cur) > MAX_PX do
        begin
          Cut:= Length(Cur);
          while (Cut > 1) and (Cv.TextWidth(Copy(Cur, 1, Cut)) > MAX_PX) do Dec(Cut);
          L.Add(Copy(Cur, 1, Cut));
          Cur:= Copy(Cur, Cut + 1, MaxInt);
        end;
      end;
    end;
    if Cur <> '' then L.Add(Cur);
    Result:= L.ToArray;
  finally
    L.Free;
  end;
end;

function TFlowChartControl.BoxLines(AIndex: Integer): TArray<string>;
var
  S         : TFlowStep    ;
  L         : TList<string>;
  Raw       : TList<string>;
  P         : TDocParam    ;
  E         : TDocException;
  Expanded  : Boolean      ;
  Head      : string       ;
  SeeAlsoStr: string       ;
  I         : Integer      ;

  procedure AddWrapped(const ALine: string; AHead: Boolean);
  var Seg: string;
  begin
    for Seg in WrapLine(ALine, AHead) do Raw.Add(Seg);
  end;

begin
  S:= FVM.Tree.Steps[AIndex];
  L:= TList<string>.Create;
  try
    if S.IsExternal then
      Exit(WrapLine(S.RawName + '  [external]', True));

    if S.Signature <> '' then Head:= S.Signature
    else Head:= S.SymbolId;
    if S.IsRecursion then Head:= Head + '   (recursion)';
    L.Add(Head);

    if S.Doc.HasDoc and (S.Doc.Summary <> '') then L.Add(S.Doc.Summary)
    else if not S.Doc.HasDoc then L.Add('[no doc]');

    Expanded:= FVM.EffectiveExpanded(AIndex);
    if Expanded and S.Doc.HasDoc then
    begin
      for P in S.Doc.Params do L.Add('  param ' + P.Name + ' - ' + P.Desc);
      if S.Doc.ReturnsText <> '' then L.Add('  returns ' + S.Doc.ReturnsText);
      for E in S.Doc.Exceptions do L.Add('  raises ' + E.TypeName);
      if S.Doc.Remarks <> '' then L.Add('  remarks ' + S.Doc.Remarks);
      if Length(S.Doc.SeeAlso) > 0 then
      begin
        SeeAlsoStr:= '';
        for I:= 0 to High(S.Doc.SeeAlso) do
        begin
          if I > 0 then SeeAlsoStr:= SeeAlsoStr + ', ';
          SeeAlsoStr:= SeeAlsoStr + S.Doc.SeeAlso[I];
        end;
        L.Add('  see also: ' + SeeAlsoStr);
      end;
    end; // if

    if (S.Depth = 0) and (Length(S.ChildIndices) = 0) and (S.TruncatedChildren = 0) and (not S.IsExternal) then L.Add('(no outgoing calls)');

    { The "... N more" line MUST stay the LAST line appended when there is
      truncation -- Relayout pins the clickable expand hit-rect to the last
      line index. Do not append anything after this. }
    if S.TruncatedChildren > 0 then L.Add('  ... ' + IntToStr(S.TruncatedChildren) + ' more');

    { Word-wrap every logical line to the box width; the first line is the bold
      head. The "... N more" line stays last (it is short and never wraps), so
      Relayout's last-line hit-rect still lands on it. }
    Raw:= TList<string>.Create;
    try
      for I:= 0 to L.Count - 1 do AddWrapped(L[I], I = 0);
      Result:= Raw.ToArray;
    finally
      Raw.Free;
    end;
  finally
    L.Free;
  end; // try
end; // function

function TFlowChartControl.DiagDump: string;
const
  MAX_PX = BOX_W - 2 * BOX_PAD;
var
  I, J, MaxPx, W, Overflow: Integer;
  Lines: TArray<string>;
  Cv   : TCanvas;
  Flag : string;
begin
  if (FVM = nil) or (not FVM.HasTree) then Exit('flow: no tree');
  Cv:= FMeasure.Canvas;
  MaxPx:= 0; Overflow:= 0;
  for I:= 0 to High(FVM.Tree.Steps) do
  begin
    Lines:= BoxLines(I);
    for J:= 0 to High(Lines) do
    begin
      if J = 0 then Cv.Font.Style:= [fsBold] else Cv.Font.Style:= [];
      W:= Cv.TextWidth(Lines[J]);
      if W > MaxPx then MaxPx:= W;
      if W > MAX_PX then Inc(Overflow);
    end;
  end;
  if Overflow = 0 then Flag:= 'OK' else Flag:= 'OVERFLOW';
  Result:= Format('flow boxes=%d maxlinepx=%d boxtextpx=%d overflowlines=%d %s',
    [Length(FVM.Tree.Steps), MaxPx, MAX_PX, Overflow, Flag]);
end;

procedure TFlowChartControl.Relayout;
var
  I       : Integer       ;
  Y       : Integer       ;
  H       : Integer       ;
  X       : Integer       ;
  MaxRight: Integer       ;
  Lines   : TArray<string>;
  R       : TRect         ;
  TR      : TRect         ;
begin
  FBoxRects.Clear;
  FToggleRects.Clear;
  FMoreRects.Clear;
  Y:= TOP_MARGIN;
  if (FVM = nil) or (not FVM.HasTree) then
  begin
    FContentH:= Y;
    FPaint.SetBounds(0, 0, BOX_W + 2 * LEFT_MARGIN, FContentH);
    Exit;
  end;

  { Track the widest box right-edge so deep (indented) boxes are not clipped
    by a hard-coded width -- the depth cap can reach 6 levels. }
  MaxRight:= BOX_W + 2 * LEFT_MARGIN;
  for I:= 0 to High(FVM.Tree.Steps) do
  begin
    Lines:= BoxLines(I);
    H:= 2 * BOX_PAD + Length(Lines) * LINE_H;
    X:= LEFT_MARGIN + FVM.Tree.Steps[I].Depth * INDENT;
    R:= Rect(X, Y, X + BOX_W, Y + H);
    FBoxRects.Add(R);
    if R.Right + LEFT_MARGIN > MaxRight then MaxRight:= R.Right + LEFT_MARGIN;
    TR:= Rect(R.Right - TOGGLE_SZ - 4, R.Top + 4, R.Right - 4, R.Top + 4 + TOGGLE_SZ);
    FToggleRects.Add(TR);
    if FVM.Tree.Steps[I].TruncatedChildren > 0 then
      FMoreRects.Add(Rect(R.Left + BOX_PAD, R.Top + BOX_PAD + (Length(Lines) - 1) * LINE_H, R.Right, R.Top + BOX_PAD + Length(Lines) * LINE_H))
    else FMoreRects.Add(Rect(0, 0, 0, 0));
    Y:= Y + H + V_GAP;
  end; // for
  FContentH:= Y;
  FPaint.SetBounds(0, 0, MaxRight, FContentH);
end; // procedure

procedure TFlowChartControl.PaintBoxPaint(Sender: TObject);
var
  I    : Integer       ;
  J    : Integer       ;
  K    : Integer       ;
  Lines: TArray<string>;
  R    : TRect         ;
  TR   : TRect         ;
  Cv   : TCanvas       ;
  S    : TFlowStep     ;
  Tog  : string        ;
begin
  Cv:= FPaint.Canvas;
  Cv.Brush.Color:= clWindow;
  Cv.FillRect(FPaint.ClientRect);
  if (FVM = nil) or (not FVM.HasTree) then
  begin
    Cv.Font.Color:= clGrayText;
    Cv.TextOut(LEFT_MARGIN, TOP_MARGIN, 'No flow. Right-click a symbol -> Trace flow from here.');
    Exit;
  end;

  { connectors: parent bottom-left -> child top-left }
  Cv.Pen.Color:= clSilver;
  for I:= 0 to High(FVM.Tree.Steps) do
  begin
    S:= FVM.Tree.Steps[I];
    for K:= 0 to High(S.ChildIndices) do
    begin
      J:= S.ChildIndices[K];
      R := FBoxRects[I];
      TR:= FBoxRects[J];
      Cv.MoveTo(R.Left + 12, R .Bottom);
      Cv.LineTo(R.Left + 12, TR.Top   );
      Cv.LineTo(TR.Left, TR.Top);
    end;
  end;

  { boxes }
  for I:= 0 to High(FVM.Tree.Steps) do
  begin
    S:= FVM.Tree.Steps[I];
    R:= FBoxRects[I];

    if S.IsExternal then Cv.Brush.Color:= $00EFEFEF
    else if not S.Doc.HasDoc then Cv.Brush.Color:= $00F7F2EC
    else Cv.Brush.Color:= $00FBF3E8;
    Cv.Pen.Color:= $00B07A2F;
    Cv.Rectangle(R);

    Lines:= BoxLines(I);
    Cv.Brush.Style:= bsClear;
    for J:= 0 to High(Lines) do
    begin
      if J = 0 then Cv.Font.Style:= [fsBold] else Cv.Font.Style:= [];
      Cv.Font.Color:= clWindowText;
      Cv.TextOut(R.Left + BOX_PAD, R.Top + BOX_PAD + J * LINE_H, Lines[J]);
    end;
    Cv.Brush.Style:= bsSolid;

    if not S.IsExternal then
    begin
      TR:= FToggleRects[I];
      Cv.Brush.Color:= clBtnFace;
      Cv.Pen  .Color:= clGrayText;
      Cv.Rectangle(TR);
      if FVM.EffectiveExpanded(I) then Tog:= '-' else Tog:= '+';
      Cv.Brush.Style:= bsClear;
      Cv.TextOut(TR.Left + 4, TR.Top - 1, Tog);
      Cv.Brush.Style:= bsSolid;
    end;
  end; // for
end; // procedure

procedure TFlowChartControl.PaintBoxMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
  P: TPoint ;
begin
  if (FVM = nil) or (not FVM.HasTree) then Exit;
  P:= Point(X, Y);
  for I:= 0 to FToggleRects.Count - 1 do
    if (not FVM.Tree.Steps[I].IsExternal) and FToggleRects[I].Contains(P) then
    begin
      FVM.ToggleBox(I);
      Exit;
    end;
  for I:= 0 to FMoreRects.Count - 1 do
    if (FVM.Tree.Steps[I].TruncatedChildren > 0) and FMoreRects[I].Contains(P) then
    begin
      FVM.ExpandTruncation(I);
      Exit;
    end;
  for I:= 0 to FBoxRects.Count - 1 do
    if FBoxRects[I].Contains(P) then
    begin
      if Assigned(FOnSelect) and (not FVM.Tree.Steps[I].IsExternal) then FOnSelect(Self, FVM.Tree.Steps[I].SymbolId);
      Exit;
    end;
end; // procedure

end.
