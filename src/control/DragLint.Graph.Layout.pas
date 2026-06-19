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
  System.Math
  , DragLint.Graph.Types
  ;

type
  TGraphLayout = class
    strict private
      FK          : Double; { ideal edge length }
      FTemperature: Double; { max velocity magnitude per iter, decays }
      FCooling    : Double; { temperature *= cooling per iter }
      FWidth      : Double; { logical viewport extents (used to seed positions) }
      FHeight     : Double;
    public
      constructor Create;
      { Initialize random positions and zero velocities, set ideal length. }
      procedure Init(AData: TGraphData; AWidth, AHeight: Double);
      { Run AIterations rounds; returns true if temperature converged. }
      function Step(AData: TGraphData; AIterations: Integer = 1): Boolean;

      { Visible-subset layout (finding F8).  The control passes only the node
      indices and edge endpoint pairs that are currently *visible* in the
      projection, so cost is O(V^2) in the visible count rather than O(N^2)
      over the whole indexed tree.  Positions/velocities are still read and
      written on the shared TGraphData nodes via their indices, so a node keeps
      its place when it is collapsed and revealed again.
        SetScale sizes the ideal edge length + starting temperature for a graph
      of AVisibleCount nodes; call it before a fresh StepVisible run.
        AEdgeSrc[i]/AEdgeDst[i] are node indices into AData (the projection's
      representative-visible endpoints). }
      procedure SetScale(AVisibleCount: Integer; AWidth, AHeight: Double);
      function StepVisible(AData: TGraphData; const AVisibleIdx: TArray<Integer>; const AEdgeSrc, AEdgeDst: TArray<Integer>; AIterations: Integer = 1): Boolean;

      property K          : Double read FK write FK;
      property Temperature: Double read FTemperature write FTemperature;
      property Cooling    : Double read FCooling write FCooling;
  end;

implementation

uses
  System.SysUtils
  ;

constructor TGraphLayout.Create;
begin
  inherited;
  FK          := 50.0;
  FTemperature:= 100.0;
  FCooling    := 0.95;
end;

procedure TGraphLayout.Init(AData: TGraphData; AWidth, AHeight: Double);
var
  I   : Integer   ;
  N   : PGraphNode;
  Area: Double    ;
begin
  FWidth := AWidth;
  FHeight:= AHeight;
  Area:= AWidth * AHeight;
  if AData.NodeCount > 0 then FK:= Sqrt(Area / AData.NodeCount)
  else FK:= 50.0;
  FTemperature:= AWidth / 10.0;

  { Random seed: scatter nodes across the area. Deterministic via
    RandSeed = node count + 1 so test fixtures stay reproducible. }
  RandSeed:= AData.NodeCount + 1;
  for I:= 0 to AData.NodeCount - 1 do
  begin
    N:= AData.NodeAt(I);
    N.X:= Random * AWidth  - AWidth  / 2;
    N.Y:= Random * AHeight - AHeight / 2;
    N.VX:= 0;
    N.VY:= 0;
    if N.Radius < 1 then N.Radius:= 12;
  end;
end; // procedure

function TGraphLayout.Step(AData: TGraphData; AIterations: Integer): Boolean;
var
  Iter  : Integer   ;
  I     : Integer   ;
  J     : Integer   ;
  SrcIdx: Integer   ;
  DstIdx: Integer   ;
  A     : PGraphNode;
  B     : PGraphNode;
  E     : TGraphEdge;
  DX    : Double    ;
  DY    : Double    ;
  Dist  : Double    ;
  Force : Double    ;
  Gap   : Double    ;
  VLen  : Double    ;
begin
  Result:= False;
  for Iter:= 1 to AIterations do
  begin
    { 1. Reset velocities for this iter }
    for I:= 0 to AData.NodeCount - 1 do
    begin
      A:= AData.NodeAt(I);
      A.VX:= 0;
      A.VY:= 0;
    end;

    { 2. Repulsion: O(N^2). Acceptable up to a few thousand nodes;
      TODO Barnes-Hut quadtree for 10k+. }
    for I:= 0 to AData.NodeCount - 1 do
    begin
      A:= AData.NodeAt(I);
      if A.Fixed then Continue;
      for J:= 0 to AData.NodeCount - 1 do
      begin
        if I = J then Continue;
        B:= AData.NodeAt(J);
        DX:= A.X - B.X;
        DY:= A.Y - B.Y;
        Dist:= Sqrt(DX * DX + DY * DY);
        if Dist < 0.01 then Dist:= 0.01;
        { v0.46: SIZE-AWARE repulsion. Use the gap between node BOUNDARIES, not
          centre distance, so a large node (an expanded UML class-box with a big
          Radius) pushes smaller nodes (dots) clear of its footprint instead of
          letting them overlap it. As Gap -> 0 the force grows sharply. }
        Gap:= Dist - A.Radius - B.Radius;
        if Gap < 1.0 then Gap:= 1.0;
        Force:= (FK * FK) / Gap;
        A.VX:= A.VX + (DX / Dist) * Force;
        A.VY:= A.VY + (DY / Dist) * Force;
      end;
    end; // for

    { 3. Attraction along edges }
    for I:= 0 to AData.EdgeCount - 1 do
    begin
      E:= AData.EdgeAt(I);
      SrcIdx:= AData.FindNodeIndex(E.SourceId);
      DstIdx:= AData.FindNodeIndex(E.TargetId);
      if (SrcIdx < 0) or (DstIdx < 0) then Continue;
      A:= AData.NodeAt(SrcIdx);
      B:= AData.NodeAt(DstIdx);
      DX:= A.X - B.X;
      DY:= A.Y - B.Y;
      Dist:= Sqrt(DX * DX + DY * DY);
      if Dist < 0.01 then Dist:= 0.01;
      Force:= (Dist * Dist) / FK;
      if E.Weight > 0 then Force:= Force * E.Weight;
      if not A.Fixed then
      begin
        A.VX:= A.VX - (DX / Dist) * Force;
        A.VY:= A.VY - (DY / Dist) * Force;
      end;
      if not B.Fixed then
      begin
        B.VX:= B.VX + (DX / Dist) * Force;
        B.VY:= B.VY + (DY / Dist) * Force;
      end;
    end; // for

    { 4. Apply velocities, clamped to temperature }
    for I:= 0 to AData.NodeCount - 1 do
    begin
      A:= AData.NodeAt(I);
      if A.Fixed then Continue;
      VLen:= Sqrt(A.VX * A.VX + A.VY * A.VY);
      if VLen > 0.01 then
      begin
        A.X:= A.X + (A.VX / VLen) * Min(VLen, FTemperature);
        A.Y:= A.Y + (A.VY / VLen) * Min(VLen, FTemperature);
      end;
    end;

    { 5. Cool down }
    FTemperature:= FTemperature * FCooling;
  end; // for

  if FTemperature < 0.5 then Result:= True;
end; // function

procedure TGraphLayout.SetScale(AVisibleCount: Integer; AWidth, AHeight: Double);
var
  Area: Double;
begin
  FWidth := AWidth;
  FHeight:= AHeight;
  Area:= AWidth * AHeight;
  if AVisibleCount > 0 then FK:= Sqrt(Area / AVisibleCount)
  else FK:= 50.0;
  FTemperature:= AWidth / 10.0;
end;

function TGraphLayout.StepVisible(AData: TGraphData; const AVisibleIdx: TArray<Integer>; const AEdgeSrc, AEdgeDst: TArray<Integer>; AIterations: Integer): Boolean;
var
  Iter : Integer   ;
  I    : Integer   ;
  J    : Integer   ;
  A    : PGraphNode;
  B    : PGraphNode;
  DX   : Double    ;
  DY   : Double    ;
  Dist : Double    ;
  Force: Double    ;
  VLen : Double    ;
  Gap  : Double    ;
  VN   : Integer   ;
  EN   : Integer   ;
begin
  Result:= False;
  VN:= Length(AVisibleIdx);
  EN:= Length(AEdgeSrc   );
  if VN = 0 then Exit(True);
  for Iter:= 1 to AIterations do
  begin
    { 1. Reset velocities for the visible set }
    for I:= 0 to VN - 1 do
    begin
      A:= AData.NodeAt(AVisibleIdx[I]);
      A.VX:= 0;
      A.VY:= 0;
    end;

    { 2. Repulsion: O(V^2) over visible nodes only }
    for I:= 0 to VN - 1 do
    begin
      A:= AData.NodeAt(AVisibleIdx[I]);
      if A.Fixed then Continue;
      for J:= 0 to VN - 1 do
      begin
        if I = J then Continue;
        B:= AData.NodeAt(AVisibleIdx[J]);
        DX:= A.X - B.X;
        DY:= A.Y - B.Y;
        Dist:= Sqrt(DX * DX + DY * DY);
        if Dist < 0.01 then Dist:= 0.01;
        { v0.46: size-aware repulsion (see Step) -- gap between boundaries so an
          expanded class-box clears the dots around it. }
        Gap:= Dist - A.Radius - B.Radius;
        if Gap < 1.0 then Gap:= 1.0;
        Force:= (FK * FK) / Gap;
        A.VX:= A.VX + (DX / Dist) * Force;
        A.VY:= A.VY + (DY / Dist) * Force;
      end;
    end; // for

    { 3. Attraction along visible (aggregated) edges.  Each visible edge counts
      once -- aggregate weight is intentionally ignored here so a heavily
      merged edge cannot collapse its endpoints onto each other. }
    for I:= 0 to EN - 1 do
    begin
      A:= AData.NodeAt(AEdgeSrc[I]);
      B:= AData.NodeAt(AEdgeDst[I]);
      DX:= A.X - B.X;
      DY:= A.Y - B.Y;
      Dist:= Sqrt(DX * DX + DY * DY);
      if Dist < 0.01 then Dist:= 0.01;
      Force:= (Dist * Dist) / FK;
      if not A.Fixed then
      begin
        A.VX:= A.VX - (DX / Dist) * Force;
        A.VY:= A.VY - (DY / Dist) * Force;
      end;
      if not B.Fixed then
      begin
        B.VX:= B.VX + (DX / Dist) * Force;
        B.VY:= B.VY + (DY / Dist) * Force;
      end;
    end; // for

    { 4. Apply velocities, clamped to temperature }
    for I:= 0 to VN - 1 do
    begin
      A:= AData.NodeAt(AVisibleIdx[I]);
      if A.Fixed then Continue;
      VLen:= Sqrt(A.VX * A.VX + A.VY * A.VY);
      if VLen > 0.01 then
      begin
        A.X:= A.X + (A.VX / VLen) * Min(VLen, FTemperature);
        A.Y:= A.Y + (A.VY / VLen) * Min(VLen, FTemperature);
      end;
    end;

    { 5. Cool down }
    FTemperature:= FTemperature * FCooling;
  end; // for

  if FTemperature < 0.5 then Result:= True;
end; // function

end.
