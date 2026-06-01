unit MainForm;

{ Thin host form: builds IDbCatalog from --db args, wires IGraphViewModel
  and TDragLintGraphControl, shows selection/doc summary in the status bar.
  No business logic here -- all decisions live in the VM. }

interface

uses
  System.SysUtils, System.Classes, System.Math,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI,
  DragLint.Graph.Types,
  DragLint.Graph.Source,
  DragLint.Graph.Source.Db,
  DragLint.Graph.ViewModel,
  DragLint.Graph.Control;

const
  WM_LOADGRAPH = WM_USER + 100;

type
  TfrmMain = class(TForm)
  private
    FGraph:      TDragLintGraphControl;
    FStatus:     TStatusBar;
    FShowAllBtn: TButton;
    FZoomBar:    TTrackBar;
    FFitBtn:     TButton;
    FSyncingZoom: Boolean;
    FVM:         IGraphViewModel;
    FCatalog:    IDbCatalog;
    FDbPaths:    TArray<string>;
    FLoaded:     Boolean;
    procedure CreateControls;
    procedure ParseDbArgs;
    procedure RunLoad;
    procedure FormShow(Sender: TObject);
    procedure WMLoadGraph(var Msg: TMessage); message WM_LOADGRAPH;
    procedure GraphNodeClick(Sender: TObject; const A: TGraphNodeEventArgs);
    procedure GraphOpenSource(Sender: TObject; const AId: string);
    procedure GraphCrossDbJump(Sender: TObject; const AName: string);
    procedure GraphViewChanged(Sender: TObject);
    procedure ShowAllBtnClick(Sender: TObject);
    procedure UpdateShowAllButton;
    { Zoom slider helpers }
    procedure ZoomBarChange(Sender: TObject);
    procedure FitBtnClick(Sender: TObject);
    procedure GraphZoomChanged(Sender: TObject);
    { Log-scale mapping: position 0..1000 <-> zoom 0.02..20.0
      Middle (500) maps to ~1.0. }
    function  PosToZoom(APos: Integer): Double;
    function  ZoomToPos(AZoom: Double): Integer;
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
  FLoaded := False;
  CreateControls;
  ParseDbArgs;
  OnShow := FormShow;
end;

procedure TfrmMain.CreateControls;
const
  ZOOM_BAR_W = 24;   { width of vertical trackbar on right side }
  FIT_BTN_H  = 26;
  FIT_BTN_W  = 46;
  MARGIN     = 4;
begin
  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := True;
  FStatus.SimpleText := 'Loading graph...';

  { Fit button - anchored top-right, left of zoom bar }
  FFitBtn := TButton.Create(Self);
  FFitBtn.Parent  := Self;
  FFitBtn.Anchors := [akTop, akRight];
  FFitBtn.Width   := FIT_BTN_W;
  FFitBtn.Height  := FIT_BTN_H;
  FFitBtn.Top     := MARGIN;
  FFitBtn.Left    := ClientWidth - ZOOM_BAR_W - FIT_BTN_W - MARGIN * 2;
  FFitBtn.Caption := 'Fit';
  FFitBtn.OnClick := FitBtnClick;

  { Vertical zoom slider - anchored right, runs top to bottom }
  FZoomBar := TTrackBar.Create(Self);
  FZoomBar.Parent      := Self;
  FZoomBar.Anchors     := [akTop, akBottom, akRight];
  FZoomBar.Orientation := trVertical;
  FZoomBar.Width       := ZOOM_BAR_W + 8;
  FZoomBar.Top         := MARGIN;
  FZoomBar.Left        := ClientWidth - FZoomBar.Width - MARGIN;
  FZoomBar.Height      := ClientHeight - MARGIN * 2;
  FZoomBar.Min         := 0;
  FZoomBar.Max         := 1000;
  FZoomBar.Position    := ZoomToPos(1.0);
  FZoomBar.TickStyle   := tsNone;
  FZoomBar.OnChange    := ZoomBarChange;
  FSyncingZoom := False;

  FGraph := TDragLintGraphControl.Create(Self);
  FGraph.Parent := Self;
  FGraph.Align := alClient;
  FGraph.OnNodeClick    := GraphNodeClick;
  FGraph.OnOpenSource   := GraphOpenSource;
  FGraph.OnCrossDbJump  := GraphCrossDbJump;
  FGraph.OnViewChanged  := GraphViewChanged;
  FGraph.OnZoomChanged  := GraphZoomChanged;

  { "Show all units / Show top N units" toggle button anchored top-right }
  FShowAllBtn := TButton.Create(Self);
  FShowAllBtn.Parent  := Self;
  FShowAllBtn.Anchors := [akTop, akRight];
  FShowAllBtn.Width   := 220;
  FShowAllBtn.Height  := 26;
  FShowAllBtn.Top     := 4;
  FShowAllBtn.Left    := ClientWidth - FShowAllBtn.Width - ZOOM_BAR_W - FIT_BTN_W - MARGIN * 4;
  FShowAllBtn.Caption := '';
  FShowAllBtn.Visible := False;
  FShowAllBtn.OnClick := ShowAllBtnClick;
end;

procedure TfrmMain.ParseDbArgs;
var
  I:     Integer;
  S:     string;
  Count: Integer;
begin
  Count := 0;
  SetLength(FDbPaths, 0);
  I := 1;
  while I <= ParamCount do
  begin
    S := ParamStr(I);
    if (LowerCase(S) = '--db') and (I < ParamCount) then
    begin
      SetLength(FDbPaths, Count + 1);
      FDbPaths[Count] := ParamStr(I + 1);
      Inc(Count);
      Inc(I, 2);
    end
    else
      Inc(I);
  end;
end;

procedure TfrmMain.FormShow(Sender: TObject);
begin
  if not FLoaded then
  begin
    FLoaded := True;
    PostMessage(Handle, WM_LOADGRAPH, 0, 0);
  end;
end;

procedure TfrmMain.WMLoadGraph(var Msg: TMessage);
begin
  RunLoad;
  SetForegroundWindow(Handle);
end;

procedure TfrmMain.RunLoad;
begin
  { --- create VM --- }
  FVM := TGraphViewModel.Create;

  if Length(FDbPaths) = 0 then
  begin
    FGraph.Bind(FVM);
    FStatus.SimpleText := 'Pass --db <drag-lint.sqlite> to load a graph.';
    UpdateShowAllButton;
    Exit;
  end;

  { --- build catalog and open store 0 --- }
  FCatalog := TDbCatalog.Create(FDbPaths);
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
      [ExtractFileName(FDbPaths[0]), FVM.Data.NodeCount]);

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

{ Zoom log-scale mapping:
    Position 0..1000 maps to zoom 0.02..20.0 on a log scale.
    At position 500 (middle): exp(ln(0.02) + 500/1000 * (ln(20)-ln(0.02)))
      = exp(ln(0.02) + 0.5 * ln(20/0.02))
      = exp(ln(0.02) + 0.5 * ln(1000))
      = exp(ln(0.02 * sqrt(1000)))
      = 0.02 * sqrt(1000) ~= 0.632
    To get exactly 1.0 at middle we use a symmetric log range:
      ln(ZMax) = -ln(ZMin) when ZMin*ZMax = 1. Here 0.02*50=1, so use [0.02,50]
      but we clamp to [0.02,20] for the control. The slider maps linearly in
      log space between ln(0.02) and ln(20). }
const
  ZOOM_MIN: Double = 0.02;
  ZOOM_MAX: Double = 20.0;
  ZOOM_POS_MAX = 1000;

function TfrmMain.PosToZoom(APos: Integer): Double;
var
  T: Double;
begin
  if APos <= 0 then begin Result := ZOOM_MIN; Exit; end;
  if APos >= ZOOM_POS_MAX then begin Result := ZOOM_MAX; Exit; end;
  T := APos / ZOOM_POS_MAX;
  Result := Exp(Ln(ZOOM_MIN) + T * (Ln(ZOOM_MAX) - Ln(ZOOM_MIN)));
end;

function TfrmMain.ZoomToPos(AZoom: Double): Integer;
var
  T: Double;
begin
  if AZoom <= ZOOM_MIN then begin Result := 0; Exit; end;
  if AZoom >= ZOOM_MAX then begin Result := ZOOM_POS_MAX; Exit; end;
  T := (Ln(AZoom) - Ln(ZOOM_MIN)) / (Ln(ZOOM_MAX) - Ln(ZOOM_MIN));
  Result := Round(T * ZOOM_POS_MAX);
end;

procedure TfrmMain.ZoomBarChange(Sender: TObject);
begin
  { Guard: when OnZoomChanged is syncing the slider back, ignore the
    resulting OnChange so we do not recurse. }
  if FSyncingZoom then Exit;
  if FGraph = nil then Exit;
  FGraph.SetZoomLevel(PosToZoom(FZoomBar.Position));
end;

procedure TfrmMain.FitBtnClick(Sender: TObject);
begin
  if FGraph = nil then Exit;
  FGraph.FitToWindow;
end;

procedure TfrmMain.GraphZoomChanged(Sender: TObject);
begin
  { Sync slider to the new zoom without re-triggering SetZoomLevel. }
  FSyncingZoom := True;
  try
    FZoomBar.Position := ZoomToPos(FGraph.ZoomLevel);
  finally
    FSyncingZoom := False;
  end;
end;

end.
