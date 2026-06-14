unit Test.Graph.Flow.ViewModel;

interface

implementation

uses
  System.SysUtils, System.Classes,
  DragLint.Graph.TestFramework,
  DragLint.Graph.Flow,
  DragLint.Graph.Flow.ViewModel,
  Fake.FlowSource;

type
  TChangeCounter = class
    Count: Integer;
    procedure OnChanged(Sender: TObject);
  end;

procedure TChangeCounter.OnChanged(Sender: TObject);
begin
  Inc(Count);
end;

procedure Test_FlowVM_SetRootAndModes;
var
  Fake: TFakeFlowSource;
  Bld:  TFlowBuilder;
  VM:   TFlowViewModel;
  CC:   TChangeCounter;
begin
  Fake := TFakeFlowSource.Create;
  Fake.AddInfo('A', 'procedure A', True, 'a');
  Fake.AddInfo('B', 'procedure B', True, 'b');
  Fake.AddCall('A', 'B', 10);
  Bld := TFlowBuilder.Create(Fake as IFlowSource);
  VM  := TFlowViewModel.Create(Bld);
  CC  := TChangeCounter.Create;
  try
    VM.OnChanged := CC.OnChanged;

    VM.SetRoot('A');
    Check(VM.HasTree, 'tree built');
    CheckEqualsInt(1, CC.Count, 'SetRoot fired OnChanged once');

    { default mode = Brief => box 0 not expanded }
    Check(not VM.EffectiveExpanded(0), 'Brief: box 0 collapsed by default');

    VM.ToggleGlobalMode;   { -> Expanded }
    CheckEqualsInt(2, CC.Count, 'ToggleGlobalMode fired OnChanged');
    Check(VM.EffectiveExpanded(0), 'Expanded: box 0 expanded by default');

    { per-box override: collapse box 0 while global is Expanded }
    VM.ToggleBox(0);
    Check(not VM.EffectiveExpanded(0), 'override collapses box 0');
    CheckEqualsInt(3, CC.Count, 'ToggleBox fired OnChanged');
  finally
    CC.Free;
    VM.Free;
    Bld.Free;
  end;
end;

initialization
  RegisterTest('FlowVM_SetRootAndModes', Test_FlowVM_SetRootAndModes);
end.
