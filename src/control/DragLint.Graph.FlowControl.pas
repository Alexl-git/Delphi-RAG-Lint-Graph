unit DragLint.Graph.FlowControl;

{ Vertical-flowchart renderer for a TFlowViewModel. A TScrollBox host with an
  inner TPaintBox sized to the laid-out content; paints stacked detail-boxes
  joined by connectors, hit-tests clicks for select / per-box expand toggle.

  Text is ASCII only ('->' not arrows). CRLF line endings. }

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Generics.Collections,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.ExtCtrls,
  DragLint.Graph.Types,
  DragLint.Graph.Flow,
  DragLint.Graph.Flow.ViewModel;

type
  TFlowSymbolEvent = procedure(Sender: TObject; const ASymbolId: string) of object;

  /// <summary>Renders a TFlowViewModel as a scrollable vertical flowchart and
  ///  reports box selection via OnSelectSymbol.</summary>
  TFlowChartControl = class(TScrollBox)
  strict private
    FPaint:   TPaintBox;
    FVM:      TFlowViewModel;
    FBoxRects:    TList<TRect>;     { index-aligned with VM.Tree.Steps }
    FToggleRects: TList<TRect>;     { per-step +/- hit rect }
    FContentH: Integer;
    FOnSelect: TFlowSymbolEvent;
    procedure PaintBoxPaint(Sender: TObject);
    procedure PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure VMChanged(Sender: TObject);
    function  BoxLines(AIndex: Integer): TArray<string>;
    procedure Relayout;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Attach(AVM: TFlowViewModel);
    property OnSelectSymbol: TFlowSymbolEvent read FOnSelect write FOnSelect;
  end;

implementation

const
  BOX_W       = 360;
  BOX_PAD     = 8;
  LINE_H      = 16;
  V_GAP       = 28;     { vertical gap between boxes (room for connector) }
  INDENT      = 24;     { px per depth level }
  LEFT_MARGIN = 16;
  TOP_MARGIN  = 12;
  TOGGLE_SZ   = 14;

constructor TFlowChartControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FBoxRects    := TList<TRect>.Create;
  FToggleRects := TList<TRect>.Create;
  BorderStyle := bsNone;
  Color := clWindow;
  FPaint := TPaintBox.Create(Self);
  FPaint.Parent := Self;
  FPaint.OnPaint     := PaintBoxPaint;
  FPaint.OnMouseDown := PaintBoxMouseDown;
end;

destructor TFlowChartControl.Destroy;
begin
  FToggleRects.Free;
  FBoxRects.Free;
  inherited;
end;

procedure TFlowChartControl.Attach(AVM: TFlowViewModel);
begin
  FVM := AVM;
  if FVM <> nil then
    FVM.OnChanged := VMChanged;
  Relayout;
  FPaint.Invalidate;
end;

procedure TFlowChartControl.VMChanged(Sender: TObject);
begin
  Relayout;
  FPaint.Invalidate;
end;

function TFlowChartControl.BoxLines(AIndex: Integer): TArray<string>;
var
  S: TFlowStep;
  L: TList<string>;
  P: TDocParam;
  E: TDocException;
  Expanded: Boolean;
  Head: string;
  SeeAlsoStr: string;
  I: Integer;
begin
  S := FVM.Tree.Steps[AIndex];
  L := TList<string>.Create;
  try
    if S.IsExternal then
    begin
      L.Add(S.RawName + '  [external]');
      Exit(L.ToArray);
    end;

    if S.Signature <> '' then Head := S.Signature
                         else Head := S.SymbolId;
    if S.IsRecursion then Head := Head + '   (recursion)';
    L.Add(Head);

    if S.Doc.HasDoc and (S.Doc.Summary <> '') then
      L.Add(S.Doc.Summary)
    else if not S.Doc.HasDoc then
      L.Add('[no doc]');

    Expanded := FVM.EffectiveExpanded(AIndex);
    if Expanded and S.Doc.HasDoc then
    begin
      for P in S.Doc.Params do
        L.Add('  param ' + P.Name + ' - ' + P.Desc);
      if S.Doc.ReturnsText <> '' then
        L.Add('  returns ' + S.Doc.ReturnsText);
      for E in S.Doc.Exceptions do
        L.Add('  raises ' + E.TypeName);
      if S.Doc.Remarks <> '' then
        L.Add('  remarks ' + S.Doc.Remarks);
      if Length(S.Doc.SeeAlso) > 0 then
      begin
        SeeAlsoStr := '';
        for I := 0 to High(S.Doc.SeeAlso) do
        begin
          if I > 0 then SeeAlsoStr := SeeAlsoStr + ', ';
          SeeAlsoStr := SeeAlsoStr + S.Doc.SeeAlso[I];
        end;
        L.Add('  see also: ' + SeeAlsoStr);
      end;
    end;

    if S.TruncatedChildren > 0 then
      L.Add('  ... ' + IntToStr(S.TruncatedChildren) + ' more');

    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

procedure TFlowChartControl.Relayout;
var
  I, Y, H, X: Integer;
  Lines: TArray<string>;
  R, TR: TRect;
begin
  FBoxRects.Clear;
  FToggleRects.Clear;
  Y := TOP_MARGIN;
  if (FVM = nil) or (not FVM.HasTree) then
  begin
    FContentH := Y;
    FPaint.SetBounds(0, 0, BOX_W + 4 * INDENT + 2 * LEFT_MARGIN, FContentH);
    Exit;
  end;

  for I := 0 to High(FVM.Tree.Steps) do
  begin
    Lines := BoxLines(I);
    H := 2 * BOX_PAD + Length(Lines) * LINE_H;
    X := LEFT_MARGIN + FVM.Tree.Steps[I].Depth * INDENT;
    R := Rect(X, Y, X + BOX_W, Y + H);
    FBoxRects.Add(R);
    TR := Rect(R.Right - TOGGLE_SZ - 4, R.Top + 4,
               R.Right - 4, R.Top + 4 + TOGGLE_SZ);
    FToggleRects.Add(TR);
    Y := Y + H + V_GAP;
  end;
  FContentH := Y;
  FPaint.SetBounds(0, 0, BOX_W + 5 * INDENT + 2 * LEFT_MARGIN, FContentH);
end;

procedure TFlowChartControl.PaintBoxPaint(Sender: TObject);
var
  I, J, K: Integer;
  Lines: TArray<string>;
  R, TR: TRect;
  Cv: TCanvas;
  S: TFlowStep;
  Tog: string;
begin
  Cv := FPaint.Canvas;
  Cv.Brush.Color := clWindow;
  Cv.FillRect(FPaint.ClientRect);
  if (FVM = nil) or (not FVM.HasTree) then
  begin
    Cv.Font.Color := clGrayText;
    Cv.TextOut(LEFT_MARGIN, TOP_MARGIN,
      'No flow. Right-click a symbol -> Trace flow from here.');
    Exit;
  end;

  { connectors: parent bottom-left -> child top-left }
  Cv.Pen.Color := clSilver;
  for I := 0 to High(FVM.Tree.Steps) do
  begin
    S := FVM.Tree.Steps[I];
    for K := 0 to High(S.ChildIndices) do
    begin
      J := S.ChildIndices[K];
      R  := FBoxRects[I];
      TR := FBoxRects[J];
      Cv.MoveTo(R.Left + 12, R.Bottom);
      Cv.LineTo(R.Left + 12, TR.Top);
      Cv.LineTo(TR.Left, TR.Top);
    end;
  end;

  { boxes }
  for I := 0 to High(FVM.Tree.Steps) do
  begin
    S := FVM.Tree.Steps[I];
    R := FBoxRects[I];

    if S.IsExternal then Cv.Brush.Color := $00EFEFEF
    else if not S.Doc.HasDoc then Cv.Brush.Color := $00F7F2EC
    else Cv.Brush.Color := $00FBF3E8;
    Cv.Pen.Color := $00B07A2F;
    Cv.Rectangle(R);

    Lines := BoxLines(I);
    Cv.Brush.Style := bsClear;
    for J := 0 to High(Lines) do
    begin
      if J = 0 then Cv.Font.Style := [fsBold] else Cv.Font.Style := [];
      Cv.Font.Color := clWindowText;
      Cv.TextOut(R.Left + BOX_PAD, R.Top + BOX_PAD + J * LINE_H, Lines[J]);
    end;
    Cv.Brush.Style := bsSolid;

    if not S.IsExternal then
    begin
      TR := FToggleRects[I];
      Cv.Brush.Color := clBtnFace;
      Cv.Pen.Color := clGrayText;
      Cv.Rectangle(TR);
      if FVM.EffectiveExpanded(I) then Tog := '-' else Tog := '+';
      Cv.Brush.Style := bsClear;
      Cv.TextOut(TR.Left + 4, TR.Top - 1, Tog);
      Cv.Brush.Style := bsSolid;
    end;
  end;
end;

procedure TFlowChartControl.PaintBoxMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
  P: TPoint;
begin
  if (FVM = nil) or (not FVM.HasTree) then Exit;
  P := Point(X, Y);
  for I := 0 to FToggleRects.Count - 1 do
    if (not FVM.Tree.Steps[I].IsExternal) and FToggleRects[I].Contains(P) then
    begin
      FVM.ToggleBox(I);
      Exit;
    end;
  for I := 0 to FBoxRects.Count - 1 do
    if FBoxRects[I].Contains(P) then
    begin
      if Assigned(FOnSelect) and (not FVM.Tree.Steps[I].IsExternal) then
        FOnSelect(Self, FVM.Tree.Steps[I].SymbolId);
      Exit;
    end;
end;

end.
