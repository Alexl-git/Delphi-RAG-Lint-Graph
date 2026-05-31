unit DragLint.Graph.TestFramework;

{ Minimal dependency-free test harness. Mirrors drag-lint's console autotest:
  each registered test runs; any failed Check increments the test's failure
  count; RunAllTests returns the number of failed tests for use as ExitCode. }

interface

type
  TTestProc = procedure;

procedure RegisterTest(const AName: string; AProc: TTestProc);
procedure Check(ACondition: Boolean; const AMessage: string);
procedure CheckEqualsInt(AExpected, AActual: Integer; const AMessage: string);
procedure CheckEqualsStr(const AExpected, AActual, AMessage: string);
function RunAllTests: Integer;

implementation

uses
  System.SysUtils, System.Generics.Collections;

type
  TTestEntry = record
    Name: string;
    Proc: TTestProc;
  end;

var
  GTests: TList<TTestEntry>;
  GCurrentFailures: Integer;

procedure RegisterTest(const AName: string; AProc: TTestProc);
var
  E: TTestEntry;
begin
  E.Name := AName;
  E.Proc := AProc;
  GTests.Add(E);
end;

procedure Fail(const AMessage: string);
begin
  Inc(GCurrentFailures);
  WriteLn('    FAIL: ' + AMessage);
end;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then Fail(AMessage);
end;

procedure CheckEqualsInt(AExpected, AActual: Integer; const AMessage: string);
begin
  if AExpected <> AActual then
    Fail(Format('%s (expected %d, got %d)', [AMessage, AExpected, AActual]));
end;

procedure CheckEqualsStr(const AExpected, AActual, AMessage: string);
begin
  if AExpected <> AActual then
    Fail(Format('%s (expected "%s", got "%s")', [AMessage, AExpected, AActual]));
end;

function RunAllTests: Integer;
var
  I: Integer;
  E: TTestEntry;
begin
  Result := 0;
  for I := 0 to GTests.Count - 1 do
  begin
    E := GTests[I];
    GCurrentFailures := 0;
    try
      E.Proc;
    except
      on Ex: Exception do
      begin
        Inc(GCurrentFailures);
        WriteLn('    EXCEPTION: ' + Ex.ClassName + ': ' + Ex.Message);
      end;
    end;
    if GCurrentFailures = 0 then
      WriteLn('  [PASS] ' + E.Name)
    else
    begin
      WriteLn('  [FAIL] ' + E.Name);
      Inc(Result);
    end;
  end;
  WriteLn('');
  WriteLn(Format('%d test(s), %d failed', [GTests.Count, Result]));
end;

initialization
  GTests := TList<TTestEntry>.Create;
finalization
  GTests.Free;
end.
