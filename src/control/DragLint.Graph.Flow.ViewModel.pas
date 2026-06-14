unit DragLint.Graph.Flow.ViewModel;

{ Interaction state for the flow view: current tree, global Brief/Expanded
  mode, and per-box expand/collapse overrides. UI-agnostic (no VCL) so it is
  unit-testable; the control observes OnChanged and repaints.

  ASCII / CRLF per the project rule. }

interface

uses
  System.Classes, System.Generics.Collections,
  DragLint.Graph.Flow;

type
  /// <summary>Display granularity: fmBrief shows signature only; fmExpanded shows full doc.</summary>
  TFlowMode = (fmBrief, fmExpanded);

  /// <summary>Holds the built flow tree plus view state. Build a tree with
  ///  SetRoot; flip detail with ToggleGlobalMode; override one box with
  ///  ToggleBox. EffectiveExpanded answers what the renderer should draw.</summary>
  TFlowViewModel = class
  strict private
    FBuilder:   TFlowBuilder;
    FTree:      TFlowTree;
    FHasTree:   Boolean;
    FMode:      TFlowMode;
    FRootId:    string;
    FOverrides: TDictionary<Integer, Boolean>;  { step idx -> expanded? }
    FExpanded:  TDictionary<string, Boolean>;   { symbol ids with cap lifted }
    FOnChanged: TNotifyEvent;
    procedure Changed;
    procedure Rebuild;
  public
    constructor Create(ABuilder: TFlowBuilder);
    destructor Destroy; override;
    /// <summary>Builds a new flow tree from ARootId and notifies observers.</summary>
    procedure SetRoot(const ARootId: string);
    /// <summary>Flips between fmBrief and fmExpanded, clearing per-box overrides.</summary>
    procedure ToggleGlobalMode;
    /// <summary>Inverts the expanded state of the box at AStepIndex.</summary>
    procedure ToggleBox(AStepIndex: Integer);
    /// <summary>Returns True if AStepIndex should be rendered expanded (mode + override).</summary>
    function  EffectiveExpanded(AStepIndex: Integer): Boolean;
    /// <summary>Lifts the depth/breadth cap for the node at AStepIndex and rebuilds.</summary>
    procedure ExpandTruncation(AStepIndex: Integer);
    property  Tree: TFlowTree read FTree;
    property  HasTree: Boolean read FHasTree;
    property  Mode: TFlowMode read FMode;
    property  OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

implementation

constructor TFlowViewModel.Create(ABuilder: TFlowBuilder);
begin
  inherited Create;
  FBuilder   := ABuilder;
  FMode      := fmBrief;
  FOverrides := TDictionary<Integer, Boolean>.Create;
  FExpanded  := TDictionary<string, Boolean>.Create;
end;

destructor TFlowViewModel.Destroy;
begin
  FExpanded.Free;
  FOverrides.Free;
  inherited;
end;

procedure TFlowViewModel.Changed;
begin
  if Assigned(FOnChanged) then FOnChanged(Self);
end;

procedure TFlowViewModel.Rebuild;
begin
  FTree := FBuilder.Build(FRootId, FExpanded.Keys.ToArray);
  FHasTree := Length(FTree.Steps) > 0;
  Changed;
end;

procedure TFlowViewModel.SetRoot(const ARootId: string);
begin
  FRootId := ARootId;
  FOverrides.Clear;
  FExpanded.Clear;
  Rebuild;
end;

procedure TFlowViewModel.ToggleGlobalMode;
begin
  if FMode = fmBrief then FMode := fmExpanded else FMode := fmBrief;
  FOverrides.Clear;   { a global flip resets per-box overrides }
  Changed;
end;

procedure TFlowViewModel.ToggleBox(AStepIndex: Integer);
begin
  FOverrides.AddOrSetValue(AStepIndex, not EffectiveExpanded(AStepIndex));
  Changed;
end;

function TFlowViewModel.EffectiveExpanded(AStepIndex: Integer): Boolean;
begin
  if not FOverrides.TryGetValue(AStepIndex, Result) then
    Result := (FMode = fmExpanded);
end;

procedure TFlowViewModel.ExpandTruncation(AStepIndex: Integer);
begin
  if (AStepIndex >= 0) and (AStepIndex <= High(FTree.Steps)) and
     (FTree.Steps[AStepIndex].TruncatedChildren > 0) then
  begin
    FExpanded.AddOrSetValue(FTree.Steps[AStepIndex].SymbolId, True);
    Rebuild;
  end;
end;

end.
