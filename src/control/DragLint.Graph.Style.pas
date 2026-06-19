unit DragLint.Graph.Style;

{ Pure visual mapping for the graph View. No VCL: colors are Cardinal
  $00RRGGBB (assignable straight to TColor), shapes/dashes are enums.
  This keeps styling headlessly unit-testable. }

interface

uses
  DragLint.Graph.Types
  ;

type
  TNodeShape = (nsEllipse, nsBox, nsRoundBox, nsDiamond, nsHexagon, nsCylinder, nsTag, nsTriangle);
  TEdgeDash  = (edSolid, edDash, edBold);

  TNodeStyle = record
    Fill : Cardinal  ; { $00RRGGBB }
    Shape: TNodeShape;
  end;

  TEdgeStyle = record
    Color: Cardinal ;
    Width: Integer  ;
    Dash : TEdgeDash;
    Arrow: Boolean  ;
  end;

const
  CL_PROJECT   = Cardinal($00808080);
  CL_UNIT      = Cardinal($00C4A484);
  CL_TYPE      = Cardinal($0066D9EF);
  CL_MEMBER    = Cardinal($00A6E22E);
  CL_SQL       = Cardinal($00B5651D); { steel/earth for SQL kinds }
  CL_OTHER     = Cardinal($00909090);
  CL_EDGE      = Cardinal($00606060);
  CL_EDGE_USES = Cardinal($007090C0);
  CL_EDGE_CALL = Cardinal($0080C080);
  CL_EDGE_TYPE = Cardinal($00C0A060);
  CL_EDGE_XDB  = Cardinal($000080FF); { cross-DB accent }

function NodeStyleFor(AKind: TGraphNodeKind): TNodeStyle                                                        ;
function EdgeStyleFor(AKind: TGraphEdgeKind; const ASection: string; AAggregated, ACrossDb: Boolean): TEdgeStyle;
{ UML visibility glyph for a member's modifiers string:
    +  public      -  private      #  protected      ~  published
  Returns '' when no visibility is known (free procs, units, etc.). }
function VisibilityGlyph(const AModifiers: string): string;

implementation

{ ASCII-only case-insensitive comparison; avoids System.SysUtils dependency }
function SectionIs(const ASection, ARef: string): Boolean;
var
  I: Integer;
begin
  Result:= False;
  if Length(ASection) <> Length(ARef) then Exit;
  for I:= 1 to Length(ARef) do
    if UpCase(ASection[I]) <> UpCase(ARef[I]) then Exit;
  Result:= True;
end;

function NodeStyleFor(AKind: TGraphNodeKind): TNodeStyle;
begin
  case AKind of
    nkProject:
    begin Result.Fill:= CL_PROJECT; Result.Shape:= nsRoundBox; end;
    nkUnit:
    begin Result.Fill:= CL_UNIT; Result.Shape:= nsBox; end;
    nkClass, nkInterface, nkRecord, nkType:
    begin Result.Fill:= CL_TYPE; Result.Shape:= nsRoundBox; end;
    nkMethod, nkProcedure, nkFunction, nkProperty, nkField, nkConst, nkVar:
    begin Result.Fill:= CL_MEMBER; Result.Shape:= nsEllipse; end;
    nkSqlTable, nkSqlView:
    begin Result.Fill:= CL_SQL; Result.Shape:= nsBox; end;
    nkSqlColumn, nkSqlDomain:
    begin Result.Fill:= CL_SQL; Result.Shape:= nsTag; end;
    nkSqlIndex:
    begin Result.Fill:= CL_SQL; Result.Shape:= nsDiamond; end;
    nkSqlTrigger:
    begin Result.Fill:= CL_SQL; Result.Shape:= nsHexagon; end;
    nkSqlGenerator:
    begin Result.Fill:= CL_SQL; Result.Shape:= nsCylinder; end;
    nkSqlProcedure:
    begin Result.Fill:= CL_SQL; Result.Shape:= nsRoundBox; end;
    nkSqlException:
    begin Result.Fill:= CL_SQL; Result.Shape:= nsTriangle; end;
    nkDfmForm:
    begin Result.Fill:= CL_TYPE; Result.Shape:= nsBox; end;
    else
    begin Result.Fill:= CL_OTHER; Result.Shape:= nsEllipse; end;
  end; // case
end; // function

function VisibilityGlyph(const AModifiers: string): string;
{ case-insensitive substring test; W must be lowercase (no SysUtils dep) }
  function HasWord(const S, W: string): Boolean;
  var
    I : Integer;
    J : Integer;
    Ok: Boolean;
    C : Char   ;
  begin
    Result:= False;
    if (S = '') or (Length(W) > Length(S)) then Exit;
    for I:= 1 to Length(S) - Length(W) + 1 do
    begin
      Ok:= True;
      for J:= 1 to Length(W) do
      begin
        C:= S[I + J - 1];
        if (C >= 'A') and (C <= 'Z') then C:= Chr(Ord(C) + 32);
        if C <> W[J] then begin Ok:= False; Break; end;
      end;
      if Ok then Exit(True);
    end;
  end;
begin
  { check 'published' before 'public' (distinct, but explicit for clarity) }
  if HasWord(AModifiers, 'published') then Result:= '~'
  else if HasWord(AModifiers, 'protected') then Result:= '#'
  else if HasWord(AModifiers, 'private'  ) then Result:= '-'
  else if HasWord(AModifiers, 'public'   ) then Result:= '+'
  else Result:= '';
end;

function EdgeStyleFor(AKind: TGraphEdgeKind; const ASection: string; AAggregated, ACrossDb: Boolean): TEdgeStyle;
begin
  Result.Arrow:= True;
  Result.Width:= 1;
  case AKind of
    ekUses:
    begin
      Result.Color:= CL_EDGE_USES;
      if SectionIs(ASection, 'interface') then Result.Dash:= edSolid
      else if SectionIs(ASection, 'implementation') then Result.Dash:= edDash
      else if (ASection <> '') then { program | package }
        Result.Dash:= edBold
      else Result.Dash:= edSolid;
    end;
    ekCalls:
    begin Result.Color:= CL_EDGE_CALL; Result.Dash:= edSolid; end;
    ekTypeRef, ekInherits, ekImplements:
    begin Result.Color:= CL_EDGE_TYPE; Result.Dash:= edSolid; end;
    ekSqlTableRef:
    begin Result.Color:= CL_SQL; Result.Dash:= edSolid; end;
    else
    begin Result.Color:= CL_EDGE; Result.Dash:= edSolid; end;
  end; // case
  if AAggregated then
  begin
    Result.Width:= 2;
    Result.Color:= CL_EDGE; { neutral for mixed/aggregated }
  end;
  if ACrossDb then
  begin
    Result.Color:= CL_EDGE_XDB;
    Result.Dash := edDash;
  end;
end; // function

end.
