unit DragLint.Graph.Layout;

{ Force-directed layout (Fruchterman-Reingold variant) for TGraphData.

  Iteration loop:
    1. Each pair of nodes pushes apart by  Frep = k*k / d   (repulsion)
    2. Each edge pulls its endpoints together by  Fatt = d*d / k   (attraction)
    3. Velocity is clamped to a cooling "temperature" that decays per iter.
    4. Position += velocity. Optionally bounded to the canvas.

  For Micronite-scale graphs (~thousands of nodes) we pay O(N^2) per
  iteration, but each iter is one tight Pascal loop with no allocations.
  Around 200 iterations gets a usable layout on a few-thousand-node graph
  in well under a second on a modern machine. For 40k+, swap the all-pairs
  repulsion for a Barnes-Hut quadtree (TODO marked below).

  All math uses Double. World coordinates are dimensionless;
  TDragLintGraphControl maps them to pixels via a pan/zoom transform. }

interface

uses
  System.Math,
  DragLint.Graph.Types;

type
  TGraphLayout = class
  strict private
    FK:           Double;   { ideal edge length }
    FTemperature: Double;   { max velocity magnitude per iter, decays }
    FCooling:     Double;   { temperature *= cooling per iter }
    FWidth:       Double;   { logical viewport extents (used to seed positions) }
    FHeight:      Double;
    procedure Reset(AData: TGraphData);
  public
    constructor Create;
    { Initialize random positions and zero velocities, set ideal length. }
    procedure Init(AData: TGraphData; AWidth, AHeight: Double);
    { Run AIterations rounds; returns true if temperature converged. }
    function Step(AData: TGraphData; AIterations: Integer = 1): Boolean;

    property K:           Double read FK           write FK;
    property Temperature: Double read FTemperature write FTemperature;
    property Cooling:     Double read FCooling     write FCooling;
  end;

implementation

uses
  System.SysUtils;

constructor TGraphLayout.Create;
begin
  inherited;
  FK := 50.0;
  FTemperature := 100.0;
  FCooling := 0.95;
end;

procedure TGraphLayout.Reset(AData: TGraphData);
var
  I: Integer;
  N: PGraphNode;
begin
  for I := 0 to AData.NodeCount - 1 do
  begin
    N := AData.NodeAt(I);
    N.VX := 0;
    N.VY := 0;
  end;
end;

procedure TGraphLayout.Init(AData: TGraphData; AWidth, AHeight: Double);
var
  I:    Integer;
  N:    PGraphNode;
  Area: Double;
begin
  FWidth  := AWidth;
  FHeight := AHeight;
  Area    := AWidth * AHeight;
  if AData.NodeCount > 0 then
    FK := Sqrt(Area / AData.NodeCount)
  else
    FK := 50.0;
  FTemperature := AWidth / 10.0;

  { Random seed: scatter nodes across the area. Deterministic via
    RandSeed = node count + 1 so test fixtures stay reproducible. }
  RandSeed := AData.NodeCount + 1;
  for I := 0 to AData.NodeCount - 1 do
  begin
    N := AData.NodeAt(I);
    N.X      := Random * AWidth  - AWidth  / 2;
    N.Y      := Random * AHeight - AHeight / 2;
    N.VX     := 0;
    N.VY     := 0;
    if N.Radius < 1 then N.Radius := 12;
  end;
end;

function TGraphLayout.Step(AData: TGraphData; AIterations: Integer): Boolean;
var
  Iter, I, J, SrcIdx, DstIdx: Integer;
  A, B: PGraphNode;
  E: TGraphEdge;
  DX, DY, Dist, Force: Double;
  VLen: Double;
begin
  Result := False;
  for Iter := 1 to AIterations do
  begin
    { 1. Reset velocities for this iter }
    for I := 0 to AData.NodeCount - 1 do
    begin
      A := AData.NodeAt(I);
      A.VX := 0;
      A.VY := 0;
    end;

    { 2. Repulsion: O(N^2). Acceptable up to a few thousand nodes;
      TODO Barnes-Hut quadtree for 10k+. }
    for I := 0 to AData.NodeCount - 1 do
    begin
      A := AData.NodeAt(I);
      if A.Fixed then Continue;
      for J := 0 to AData.NodeCount - 1 do
      begin
        if I = J then Continue;
        B := AData.NodeAt(J);
        DX := A.X - B.X;
        DY := A.Y - B.Y;
        Dist := Sqrt(DX * DX + DY * DY);
        if Dist < 0.01 then Dist := 0.01;
        Force := (FK * FK) / Dist;
        A.VX := A.VX + (DX / Dist) * Force;
        A.VY := A.VY + (DY / Dist) * Force;
      end;
    end;

    { 3. Attraction along edges }
    for I := 0 to AData.EdgeCount - 1 do
    begin
      E := AData.EdgeAt(I);
      SrcIdx := AData.FindNodeIndex(E.SourceId);
      DstIdx := AData.FindNodeIndex(E.TargetId);
      if (SrcIdx < 0) or (DstIdx < 0) then Continue;
      A := AData.NodeAt(SrcIdx);
      B := AData.NodeAt(DstIdx);
      DX := A.X - B.X;
      DY := A.Y - B.Y;
      Dist := Sqrt(DX * DX + DY * DY);
      if Dist < 0.01 then Dist := 0.01;
      Force := (Dist * Dist) / FK;
      if E.Weight > 0 then Force := Force * E.Weight;
      if not A.Fixed then
      begin
        A.VX := A.VX - (DX / Dist) * Force;
        A.VY := A.VY - (DY / Dist) * Force;
      end;
      if not B.Fixed then
      begin
        B.VX := B.VX + (DX / Dist) * Force;
        B.VY := B.VY + (DY / Dist) * Force;
      end;
    end;

    { 4. Apply velocities, clamped to temperature }
    for I := 0 to AData.NodeCount - 1 do
    begin
      A := AData.NodeAt(I);
      if A.Fixed then Continue;
      VLen := Sqrt(A.VX * A.VX + A.VY * A.VY);
      if VLen > 0.01 then
      begin
        A.X := A.X + (A.VX / VLen) * Min(VLen, FTemperature);
        A.Y := A.Y + (A.VY / VLen) * Min(VLen, FTemperature);
      end;
    end;

    { 5. Cool down }
    FTemperature := FTemperature * FCooling;
  end;

  if FTemperature < 0.5 then
    Result := True;
end;

end.
