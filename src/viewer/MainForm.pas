unit MainForm;

{ Thin host form: builds IDbCatalog from --db args, wires IGraphViewModel
  and TDragLintGraphControl, shows selection/doc summary in the status bar.
  No business logic here -- all decisions live in the VM. }

interface

uses
  System.SysUtils, System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Winapi.Windows, Winapi.ShellAPI,
  DragLint.Graph.Types,
  DragLint.Graph.Source,
  DragLint.Graph.Source.Db,
  DragLint.Graph.ViewModel,
  DragLint.Graph.Control;

type
  TfrmMain = class(TForm)
  private
    FGraph:      TDragLintGraphControl;
    FStatus:     TStatusBar;
    FShowAllBtn: TButton;
    FVM:         IGraphViewModel;
    FCatalog:    IDbCatalog;
    procedure CreateControls;
    procedure ParseAndLoad;
    procedure GraphNodeClick(Sender: TObject; const A: TGraphNodeEventArgs);
    procedure GraphOpenSource(Sender: TObject; const AId: string);
    procedure GraphCrossDbJump(Sender: TObject; const AName: string);
    procedure GraphViewChanged(Sender: TObject);
    procedure ShowAllBtnClick(Sender: TObject);
    procedure UpdateShowAllButton;
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
  ParseAndLoad;
end;

procedure TfrmMain.CreateControls;
begin
  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := True;
  FStatus.SimpleText :=
    'Pan: drag empty area | Zoom: mouse wheel | Click node to select | Ctrl+click to open source';

  FGraph := TDragLintGraphControl.Create(Self);
  FGraph.Parent := Self;
  FGraph.Align := alClient;
  FGraph.OnNodeClick    := GraphNodeClick;
  FGraph.OnOpenSource   := GraphOpenSource;
  FGraph.OnCrossDbJump  := GraphCrossDbJump;
  FGraph.OnViewChanged  := GraphViewChanged;

  { "Show all units / Show top N units" toggle button anchored top-right }
  FShowAllBtn := TButton.Create(Self);
  FShowAllBtn.Parent  := Self;
  FShowAllBtn.Anchors := [akTop, akRight];
  FShowAllBtn.Width   := 220;
  FShowAllBtn.Height  := 26;
  FShowAllBtn.Top     := 4;
  FShowAllBtn.Left    := ClientWidth - FShowAllBtn.Width - 4;
  FShowAllBtn.Caption := '';
  FShowAllBtn.Visible := False;
  FShowAllBtn.OnClick := ShowAllBtnClick;
end;

procedure TfrmMain.ParseAndLoad;
var
  I:     Integer;
  S:     string;
  Paths: array of string;
  Count: Integer;
begin
  { --- collect --db <path> arguments (repeatable) --- }
  Count := 0;
  SetLength(Paths, 0);
  I := 1;
  while I <= ParamCount do
  begin
    S := ParamStr(I);
    if (LowerCase(S) = '--db') and (I < ParamCount) then
    begin
      SetLength(Paths, Count + 1);
      Paths[Count] := ParamStr(I + 1);
      Inc(Count);
      Inc(I, 2);
    end
    else
      Inc(I);
  end;

  { --- create VM --- }
  FVM := TGraphViewModel.Create;

  if Count = 0 then
  begin
    FGraph.Bind(FVM);
    FStatus.SimpleText := 'Pass --db <drag-lint.sqlite> to load a graph.';
    UpdateShowAllButton;
    Exit;
  end;

  { --- build catalog and open store 0 --- }
  FCatalog := TDbCatalog.Create(Paths);
  FVM.SetCatalog(FCatalog);

  try
    FVM.OpenStore(0);
  except
    on E: Exception do
    begin
      FGraph.Bind(FVM);
      FStatus.SimpleText := 'Error opening store 0: ' + E.Message;
      UpdateShowAllButton;
      Exit;
    end;
  end;

  FGraph.Bind(FVM);

  if FVM.Data.NodeCount = 0 then
    FStatus.SimpleText := 'Pass --db <drag-lint.sqlite> to load a graph.'
  else
    FStatus.SimpleText := Format('Loaded %s: %d nodes',
      [ExtractFileName(Paths[0]), FVM.Data.NodeCount]);

  { Force a projection pass so FHiddenTopLevelCount is current before
    UpdateShowAllButton reads it -- Bind only schedules a paint. }
  FVM.Projection;
  UpdateShowAllButton;
end;

procedure TfrmMain.GraphViewChanged(Sender: TObject);
begin
  UpdateShowAllButton;
end;

procedure TfrmMain.UpdateShowAllButton;
var
  N: Integer;
begin
  if FVM = nil then
  begin
    FShowAllBtn.Visible := False;
    Exit;
  end;
  N := FVM.HiddenTopLevelCount;
  if (not FVM.ShowAllTopLevel) and (N > 0) then
  begin
    FShowAllBtn.Caption := Format('Show all units (%d hidden)', [N]);
    FShowAllBtn.Visible := True;
  end
  else if FVM.ShowAllTopLevel then
  begin
    FShowAllBtn.Caption := 'Show top ' + IntToStr(FVM.TopLevelLimit) + ' units';
    FShowAllBtn.Visible := True;
  end
  else
    FShowAllBtn.Visible := False;
end;

procedure TfrmMain.ShowAllBtnClick(Sender: TObject);
begin
  if FVM = nil then Exit;
  { Toggle: VM fires OnChanged -> control repaints + fires OnViewChanged
    -> UpdateShowAllButton refreshes caption/visibility. }
  FVM.SetShowAllTopLevel(not FVM.ShowAllTopLevel);
end;

procedure TfrmMain.GraphNodeClick(Sender: TObject; const A: TGraphNodeEventArgs);
var
  Doc:  TGraphDoc;
  Info: string;
begin
  if A.Node = nil then Exit;
  if A.Ctrl and Assigned(FGraph.OnOpenSource) then
  begin
    { Ctrl+click is already routed to OnOpenSource by the control }
    Exit;
  end;
  Info := 'Selected: ' + A.Node.Id;
  if A.Node.FilePath <> '' then
    Info := Info + Format('  (%s:%d)', [ExtractFileName(A.Node.FilePath), A.Node.Line]);
  Doc := FVM.SelectedDoc;
  if Doc.HasDoc and (Doc.Summary <> '') then
    Info := Info + '  -- ' + Doc.Summary;
  FStatus.SimpleText := Info;
end;

procedure TfrmMain.GraphOpenSource(Sender: TObject; const AId: string);
var
  F: string;
  L: Integer;
begin
  if FVM = nil then Exit;
  if FVM.LocateSymbol(AId, F, L) and (F <> '') then
  begin
    ShellExecute(0, 'open', PChar(F), nil, nil, SW_SHOWNORMAL);
    FStatus.SimpleText := 'Opened: ' + F;
  end
  else
    FStatus.SimpleText := 'Source not found for: ' + AId;
end;

procedure TfrmMain.GraphCrossDbJump(Sender: TObject; const AName: string);
begin
  if FVM = nil then Exit;
  FVM.JumpToCrossDb(AName);
  FStatus.SimpleText := 'Jumped to: ' + AName;
end;

end.
