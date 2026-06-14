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
    FOverrides: TDictionary<Integer, Boolean>;  { step idx -> expanded? }
    FOnChanged: TNotifyEvent;
    procedure Changed;
  public
    constructor Create(ABuilder: TFlowBuilder);
    destructor Destroy; override;
    procedure SetRoot(const ARootId: string);
    procedure ToggleGlobalMode;
    procedure ToggleBox(AStepIndex: Integer);
    function  EffectiveExpanded(AStepIndex: Integer): Boolean;
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
end;

destructor TFlowViewModel.Destroy;
begin
  FOverrides.Free;
  inherited;
end;

procedure TFlowViewModel.Changed;
begin
  if Assigned(FOnChanged) then FOnChanged(Self);
end;

procedure TFlowViewModel.SetRoot(const ARootId: string);
begin
  FOverrides.Clear;
  FTree := FBuilder.Build(ARootId);
  FHasTree := Length(FTree.Steps) > 0;
  Changed;
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

end.
