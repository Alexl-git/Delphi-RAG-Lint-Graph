unit MainForm;

interface

uses
  System.SysUtils, System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Dialogs,
  Vcl.Menus, Vcl.ComCtrls,
  Winapi.Windows, Winapi.ShellAPI,
  DragLint.Graph.Types,
  DragLint.Graph.Control,
  DragLint.Graph.Json;

type
  TfrmMain = class(TForm)
  private
    FGraph:  TDragLintGraphControl;
    FStatus: TStatusBar;
    procedure GraphNodeClick(Sender: TObject; const A: TGraphNodeEventArgs);
    procedure GraphNodeHover(Sender: TObject; ANode: PGraphNode);
    procedure CreateControls;
    procedure LoadFromCmdLine;
    procedure LoadDummy;
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  frmMain: TfrmMain;

implementation

{ TfrmMain }

constructor TfrmMain.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'drag-lint-graph viewer';
  Position := poScreenCenter;
  ClientWidth := 1100;
  ClientHeight := 700;
  CreateControls;
  LoadFromCmdLine;
end;

procedure TfrmMain.CreateControls;
begin
  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := True;
  FStatus.SimpleText := 'Pan: drag empty area | Zoom: mouse wheel | Click node to select | Ctrl+click to open source';

  FGraph := TDragLintGraphControl.Create(Self);
  FGraph.Parent := Self;
  FGraph.Align := alClient;
  FGraph.OnNodeClick := GraphNodeClick;
  FGraph.OnNodeHover := GraphNodeHover;
end;

procedure TfrmMain.LoadFromCmdLine;
var
  I:        Integer;
  S:        string;
  DataPath: string;
  Data:     TGraphData;
begin
  DataPath := '';
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if (LowerCase(S) = '--data') and (I < ParamCount) then
      DataPath := ParamStr(I + 1);
  end;

  if DataPath = '' then
  begin
    LoadDummy;
    Exit;
  end;

  if not FileExists(DataPath) then
  begin
    ShowMessage('File not found: ' + DataPath);
    LoadDummy;
    Exit;
  end;

  Data := TGraphData.Create;
  try
    if LoadGraphFromFile(DataPath, Data) then
    begin
      FGraph.LoadData(Data, True);
      FStatus.SimpleText := Format('Loaded %s: %d nodes / %d edges',
        [ExtractFileName(DataPath), Data.NodeCount, Data.EdgeCount]);
    end
    else
    begin
      Data.Free;
      ShowMessage('Failed to parse JSON: ' + DataPath);
      LoadDummy;
    end;
  except
    Data.Free;
    raise;
  end;
end;

procedure TfrmMain.LoadDummy;
var
  Data: TGraphData;
  N:    TGraphNode;
  E:    TGraphEdge;

  procedure AddNode(const AId, ALabel: string; AKind: TGraphNodeKind);
  begin
    FillChar(N, SizeOf(N), 0);
    N.Id     := AId;
    N.Label_ := ALabel;
    N.Kind   := AKind;
    N.Radius := 14;
    Data.AddNode(N);
  end;

  procedure AddEdge(const Src, Dst: string; AKind: TGraphEdgeKind);
  begin
    FillChar(E, SizeOf(E), 0);
    E.SourceId := Src;
    E.TargetId := Dst;
    E.Kind     := AKind;
    E.Weight   := 1.0;
    Data.AddEdge(E);
  end;

begin
  Data := TGraphData.Create;
  AddNode('TfrmBlueprint4', 'TfrmBlueprint4', nkClass);
  AddNode('Blueprint4',     'Blueprint4',     nkUnit);
  AddNode('TdxBarManager',  'TdxBarManager',  nkClass);
  AddNode('TdxRibbon',      'TdxRibbon',      nkClass);
  AddNode('Blueprint4.dfm', 'Blueprint4.dfm', nkDfmForm);
  AddEdge('Blueprint4',     'TfrmBlueprint4', ekContains);
  AddEdge('TfrmBlueprint4', 'TdxBarManager',  ekUses);
  AddEdge('TfrmBlueprint4', 'TdxRibbon',      ekUses);
  AddEdge('TfrmBlueprint4', 'Blueprint4.dfm', ekDfmBinds);
  FGraph.LoadData(Data, True);
  FStatus.SimpleText := Format('Demo: %d nodes / %d edges (--data <file.json> to load real graph)',
    [Data.NodeCount, Data.EdgeCount]);
end;

procedure TfrmMain.GraphNodeClick(Sender: TObject; const A: TGraphNodeEventArgs);
var
  Info: string;
begin
  if A.Node = nil then Exit;
  if A.Ctrl and (A.Node.FilePath <> '') then
  begin
    { Ctrl+click: open source file in default editor (or RAD Studio
      if we're piped one — see ProjectGraphPlugin integration later). }
    ShellExecute(0, 'open', PChar(A.Node.FilePath), nil, nil, SW_SHOWNORMAL);
    FStatus.SimpleText := 'Opened: ' + A.Node.FilePath;
    Exit;
  end;
  Info := Format('Selected: %s', [A.Node.Id]);
  if A.Node.FilePath <> '' then
    Info := Info + Format('  (%s:%d)', [ExtractFileName(A.Node.FilePath), A.Node.Line]);
  FStatus.SimpleText := Info;
end;

procedure TfrmMain.GraphNodeHover(Sender: TObject; ANode: PGraphNode);
begin
  if ANode = nil then
    FStatus.SimpleText := 'Pan: drag empty area | Zoom: mouse wheel'
  else
    FStatus.SimpleText := Format('Hover: %s', [ANode.Id]);
end;

end.
