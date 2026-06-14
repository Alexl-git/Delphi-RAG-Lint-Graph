unit DragLint.Graph.Source;

{ Model gateway interfaces. A single store is read through IGraphSource;
  the ordered set of stores (project / sql / library) is held by IDbCatalog,
  which resolves names across stores in priority order (first-hit-wins).
  Pure: depends only on DragLint.Graph.Types. Implementations (FireDAC sqlite,
  JSON, in-memory fake) live elsewhere. }

interface

uses
  DragLint.Graph.Types;

type
  IGraphSource = interface
    ['{7A2E4C10-1B3D-4F6A-9C8E-2D5F0A1B3C4D}']
    function StoreIndex: Integer;
    function LoadTopology(AData: TGraphData): Boolean;
    function GetDoc(const AQName: string): TGraphDoc;
    function ResolveCref(const AText: string): TCrefResolution;
    function LocateSymbol(const AQName: string; out AFile: string;
      out ALine: Integer): Boolean;
    { Lightweight name lookup: exact qualified_name then bare name (kind-priority
      order).  Sets AQName to the found qualified_name and returns True on a
      first-hit match; returns False (AQName := '') when nothing found.
      Must NOT call LoadTopology -- runs a single indexed SELECT per store. }
    function ResolveName(const AName: string; out AQName: string): Boolean;
    { Direct callees of ASymbolId, ordered by call-site line. Only refs whose
      innermost enclosing symbol IS ASymbolId are returned (nested symbols are
      not double-counted). Unresolved calls have TargetQName=''. May contain
      duplicate targets (caller de-duplicates). Single indexed query. }
    function GetCallees(const AQName: string): TArray<TCallRef>;
    { Signature + modifiers + raw kind text for one symbol. False if absent.
      Used by the flow engine for the box header / degradation path. }
    function GetSymbolMeta(const AQName: string;
      out ASignature, AModifiers, AKindText: string): Boolean;
  end;

  IDbCatalog = interface
    ['{3F9B1E22-6C4A-4D8B-A1E3-7B2C9D0E5F61}']
    function StoreCount: Integer;
    function StorePath(AIndex: Integer): string;
    function SourceForStore(AIndex: Integer): IGraphSource;
    function ResolveAcrossStores(const AName: string): TCrossDbResolution;
  end;

implementation

end.
