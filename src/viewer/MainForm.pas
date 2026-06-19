unit MainForm;

{ Thin host form: builds IDbCatalog from --db args, wires IGraphViewModel
  and TDragLintGraphControl, shows selection/doc summary in the status bar.
  No business logic here -- all decisions live in the VM. }

interface

uses
  System.SysUtils
  , System.Classes
  , System.Math
  , System.UITypes
  , System.StrUtils
  , System.Generics.Collections
  , System.Generics.Defaults
  , System.IOUtils
  , System.JSON
  , Vcl.Controls
  , Vcl.Forms
  , Vcl.StdCtrls
  , Vcl.ExtCtrls
  , Vcl.ComCtrls
  , Vcl.Graphics
  , Vcl.Menus
  , Winapi.Windows
  , Winapi.Messages
  , Winapi.ShellAPI
  , DragLint.Graph.Types
  , DragLint.Graph.Source
  , DragLint.Graph.Source.Db
  , DragLint.Graph.ViewModel
  , DragLint.Graph.Control
  , DragLint.Graph.Style
  , DragLint.Graph.UsesQuery
  , DragLint.Graph.OpenSourceClient
  , DragLint.Graph.Flow
  , DragLint.Graph.Flow.Source.Db
  , DragLint.Graph.Flow.ViewModel
  , DragLint.Graph.FlowControl
  , System.Win.Registry
  ;

const
  WM_LOADGRAPH = WM_USER + 100;
  WM_SELFTEST  = WM_USER + 101;   { v0.49: deferred --flow/--selftest entry (posted after load) }

  { v0.48: editor-sync. The IDE plugin sends WM_COPYDATA with this magic in
    COPYDATASTRUCT.dwData and an ANSI symbol/unit name in lpData; the viewer
    resolves it to a node and centers (recording nav history, so Back undoes an
    editor-driven jump). Cross-process-safe constant -- only our plugin sends it. }
  CD_CENTER_SYMBOL = $DA61C000;

type { Structure-tree node descriptor (attached to each TTreeNode.Data).  The tree
    is lazy: each node knows just enough to populate its children on expand. }
  TStructKind = (skUnit, skSection, skCategory, skSymbol, skUsesIntf, skUsesImpl, skUsedBy);
  TStructTag  = class
    Kind     : TStructKind;
    GraphId  : string     ; { unit id (skUnit/skSection/skCategory) or symbol id (skSymbol) }
    Section  : string     ; { 'interface' / 'implementation' (skSection, skCategory) }
    Cat      : Integer    ; { category code (skCategory) }
    IsType   : Boolean    ; { skSymbol that has members -> expandable }
    Populated: Boolean    ;
  end;

  TfrmMain = class(TForm)
    private
      FGraph      : TDragLintGraphControl;
      FStatus     : TStatusBar           ;
      FShowAllBtn : TButton              ;
      FZoomBar    : TTrackBar            ;
      FFitBtn     : TButton              ;
      FBackBtn    : TButton              ; { v0.48: graph nav-history back }
      FFwdBtn     : TButton              ; { v0.48: graph nav-history forward }
      FCrumbBar   : TPanel               ;
      FSyncingZoom: Boolean              ;
      FVM         : IGraphViewModel      ;
      FCatalog    : IDbCatalog           ;
      FDbPaths    : TArray<string>       ;
      FPlatform   : string               ; { --platform win32|win64; forwarded to resolve-dbs }
      FLoaded     : Boolean              ;
      FParentHwnd : HWND                 ; { v0.43: when nonzero, embed as a WS_CHILD of this }
      { Structure panel (left dock) }
      FStructPanel: TPanel                 ;
      FStructHdr  : TPanel                 ;
      FSearchEdit : TEdit                  ;
      FPartialChk : TCheckBox              ;
      FSplitter   : TSplitter              ;
      FTree       : TTreeView              ;
      FStructTags : TObjectList<TStructTag>;
      FSyncingTree: Boolean                ;
      { Tree right-click menu (mirrors the graph's context actions) }
      FTreePopup: TPopupMenu;
      FMiTOpen  : TMenuItem ;
      FMiTGoto  : TMenuItem ;
      FMiTWhere : TMenuItem ;
      FMiTCenter: TMenuItem ;
      FTreeCtxId: string    ; { symbol id of the right-clicked tree node }
      { Flow mode: traces the call flow from a chosen symbol; overlays the graph. }
      FFlowControl    : TFlowChartControl;
      FFlowVM         : TFlowViewModel   ;
      FFlowBuilder    : TFlowBuilder     ;
      FFlowSource     : IFlowSource      ;
      FFlowBtn        : TButton          ; { returns to graph }
      FModeBtn        : TButton          ; { Brief <-> Expanded }
      FEnterFlowBtn   : TButton          ; { enter flow from the selected graph node }
      FSelectedGraphId: string           ; { id of the currently selected graph node }
      FMiTFlow   : TMenuItem  ; { "Trace flow from here" }
      procedure FlowBtnClick(Sender: TObject);
      procedure ModeBtnClick(Sender: TObject);
      procedure StartFlowFrom(const ASymbolId: string);
      procedure FlowSelected(Sender: TObject; const ASymbolId: string);
      procedure TreeCtxFlow(Sender: TObject);
      procedure UpdateModeButton;
      procedure CreateControls;
      procedure BuildStructureRoots;
      procedure ClearStructure;
      function NewTag(AKind: TStructKind; const AGraphId, ASection: string; ACat: Integer): TStructTag;
      procedure TreeExpanding(Sender: TObject; Node: TTreeNode; var AllowExpansion: Boolean);
      procedure TreeChange(Sender: TObject; Node: TTreeNode);
      procedure SelectTreeNodeById(const AId: string);
      function CategoryOf(AKind: TGraphNodeKind): Integer;
      { Search }
      procedure SearchChanged(Sender: TObject);
      procedure DoSearch;
      procedure BuildSearchResults(const ATerm: string; APartial: Boolean);
      function UnitNameOf(ANodeIdx: Integer): string;
      { v0.49: graph navigation history (ViewModel-backed) }
      procedure NavTo    (const AGraphId: string);
      procedure BackClick(Sender: TObject);
      procedure FwdClick (Sender: TObject);
      procedure UpdateNavButtons;
      { v0.48: editor-sync -- resolve an editor symbol/unit name to a graph node id }
      function ResolveSymbolToGraphId(const ASymbol: string): string;
      { Tree context menu }
      procedure TreeContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
      procedure TreeCtxOpen     (Sender: TObject);
      procedure TreeCtxGotoIntf (Sender: TObject);
      procedure TreeCtxWhereUsed(Sender: TObject);
      procedure TreeCtxCenter   (Sender: TObject);
      procedure ParseDbArgs;
      function ResolveEngineExe: string                             ;
      function SpawnCaptureStdout(const AExe, AArgs: string): string;
      procedure ResolveDbsFromEngine;
      procedure RunLoad;
      procedure FormShow(Sender: TObject);
      { v0.49: publish/clear this viewer's window handle in the registry so the
        IDE plugin can find a STANDALONE viewer (not just an embedded one) for
        editor-sync, and idle when no viewer is registered. }
      procedure PublishViewerHwnd(APublish: Boolean);
      procedure WMLoadGraph(var Msg: TMessage   ); message WM_LOADGRAPH;
      procedure WMCopyData (var Msg: TWMCopyData); message WM_COPYDATA;
      procedure WMSelfTest (var Msg: TMessage   ); message WM_SELFTEST;
      procedure GraphNodeClick(Sender: TObject; const A: TGraphNodeEventArgs);
      procedure GraphSelectionChanged(Sender: TObject);
      procedure GraphTraceFlow(Sender: TObject; const AId: string);
      procedure GraphWhereUsed(Sender: TObject; const AId: string);
      { v0.49: fill the structure panel with the precise, clickable list of callers
        of ASymbolId (from resolved call edges) + center the graph on it. }
      procedure ShowUsedBy(const ASymbolId: string);
      procedure EnterFlowBtnClick(Sender: TObject);
      procedure GraphOpenSource(Sender: TObject; ANode: PGraphNode);
      procedure GraphCrossDbJump(Sender: TObject; const AName: string);
      procedure GraphViewChanged(Sender: TObject);
      procedure ShowAllBtnClick (Sender: TObject);
      procedure UpdateShowAllButton;
      procedure UpdateBreadcrumbs;
      procedure CrumbClick(Sender: TObject);
      { Zoom slider helpers }
      procedure ZoomBarChange   (Sender: TObject);
      procedure FitBtnClick     (Sender: TObject);
      procedure GraphZoomChanged(Sender: TObject);
      { Log-scale mapping: position 0..1000 <-> zoom 0.02..20.0
      Middle (500) maps to ~1.0. }
      function PosToZoom(APos : Integer): Double;
      function ZoomToPos(AZoom: Double ): Integer;
    protected
      procedure CreateParams(var Params: TCreateParams); override;
    public
      constructor Create(AOwner: TComponent); override;
      destructor Destroy; override;
  end;

var
  frmMain: TfrmMain;

implementation

{ TfrmMain }

// v0.43: pull the value following a named switch (e.g. '--parent-hwnd 1234').
function GetParamValue(const AName: string): string;
var
  I: Integer;
begin
  Result:= '';
  for I:= 1 to ParamCount - 1 do
    if SameText(ParamStr(I), AName) then Exit(ParamStr(I + 1));
end;

{ v0.47: parent-process exit watcher. When the IDE plugin launches us with
  --parent-pid <IDE pid>, a thread blocks on the IDE process handle and
  force-exits THIS viewer when the IDE dies -- so a crashed or killed IDE never
  leaves an orphaned drag_lint_graph.exe holding the project index DB open
  (which would break a later reindex). Belt-and-suspenders to the plugin's
  kill-on-close job object. Raw CreateThread keeps it immune to a hung VCL loop;
  TerminateProcess(self) guarantees teardown. }
function ParentWatchProc(P: Pointer): DWORD; stdcall;
var
  H: THandle;
begin
  Result:= 0;
  H:= OpenProcess(SYNCHRONIZE, False, DWORD(NativeUInt(P)));
  if H = 0 then Exit;
  try
    if WaitForSingleObject(H, INFINITE) = WAIT_OBJECT_0 then TerminateProcess(GetCurrentProcess, 0);
  finally
    CloseHandle(H);
  end;
end;

procedure StartParentExitWatch(APid: Cardinal);
var
  Tid: DWORD  ;
  H  : THandle;
begin
  if APid = 0 then Exit;
  H:= CreateThread(nil, 0, @ParentWatchProc, Pointer(NativeUInt(APid)), 0, Tid);
  if H <> 0 then CloseHandle(H);
end;

procedure TfrmMain.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  { v0.43 embed mode: become a borderless child of the host (the IDE plugin's
    dockable Graph window) instead of a top-level window. }
  if FParentHwnd <> 0 then
  begin
    Params.Style:= (Params.Style and not (WS_POPUP or WS_CAPTION or WS_THICKFRAME or WS_BORDER or WS_DLGFRAME)) or WS_CHILD;
    Params.WndParent:= FParentHwnd;
    Params.ExStyle:= Params.ExStyle and not WS_EX_APPWINDOW;
  end;
end;

constructor TfrmMain.Create(AOwner: TComponent);
var
  HwndStr: string;
begin
  inherited CreateNew(AOwner);
  Caption     := 'drag-lint-graph viewer';
  Position    := poScreenCenter;
  ClientWidth := 1100;
  ClientHeight:= 700;
  FLoaded     := False;

  { v0.43: --parent-hwnd <HWND> embeds us in the IDE plugin's dock. Resolve it
    BEFORE CreateControls -- the first child-control parenting realises the form
    handle, which is when CreateParams reads FParentHwnd. }
  HwndStr:= GetParamValue('--parent-hwnd');
  if HwndStr <> '' then
  begin
    FParentHwnd:= HWND(StrToInt64Def(HwndStr, 0));
    if FParentHwnd <> 0 then
    begin
      BorderStyle:= bsNone;
      BorderIcons:= [];
      Position:= poDesigned;
      Left    := 0;
      Top     := 0;
    end;
  end;

  { v0.47: self-exit if the spawning IDE dies (no-op when --parent-pid absent). }
  StartParentExitWatch(Cardinal(StrToInt64Def(GetParamValue('--parent-pid'), 0)));

  FStructTags:= TObjectList<TStructTag>.Create(True);
  CreateControls;
  ParseDbArgs;
  OnShow:= FormShow;
end; // constructor

destructor TfrmMain.Destroy;
begin
  if HandleAllocated then PublishViewerHwnd(False);   { v0.49: stop advertising to the plugin }
  { Flow VM/builder/source are NOT owned by the form -- free them here, before
    inherited.  FFlowControl is form-owned and freed during inherited, and its
    destructor clears the VM's OnChanged -- so we must detach the control from
    the VM (Attach(nil) nils both sides) BEFORE freeing the VM, or the control's
    destructor would write through a dangling pointer. }
  if FFlowControl <> nil then FFlowControl.Attach(nil);
  FFlowVM.Free;
  FFlowBuilder.Free;
  FFlowSource:= nil;
  FStructTags.Free;
  inherited;
end;

procedure TfrmMain.CreateControls;
const
  ZOOM_BAR_W = 24; { width of vertical trackbar on right side }
  FIT_BTN_H  = 26;
  FIT_BTN_W  = 46;
  MARGIN     = 4;
begin
  FStatus:= TStatusBar.Create(Self);
  FStatus.Parent     := Self;
  FStatus.SimplePanel:= True;
  FStatus.SimpleText := 'Loading graph...';

  { Breadcrumb bar across the top -- created first so it sits below the
    top-right Fit/zoom/show-all controls in z-order. }
  FCrumbBar:= TPanel.Create(Self);
  FCrumbBar.Parent    := Self;
  FCrumbBar.Align     := alTop;
  FCrumbBar.Height    := 26;
  FCrumbBar.BevelOuter:= bvNone;
  FCrumbBar.Color:= TColor($00383838);
  FCrumbBar.ParentBackground:= False;

  { Fit button - anchored top-right, left of zoom bar }
  FFitBtn:= TButton.Create(Self);
  FFitBtn.Parent:= Self;
  FFitBtn.Anchors:= [akTop, akRight];
  FFitBtn.Width := FIT_BTN_W;
  FFitBtn.Height:= FIT_BTN_H;
  FFitBtn.Top   := MARGIN;
  FFitBtn.Left:= ClientWidth - ZOOM_BAR_W - FIT_BTN_W - MARGIN * 2;
  FFitBtn.Caption:= 'Fit';
  FFitBtn.OnClick:= FitBtnClick;

  { v0.48: graph navigation history -- Back / Forward, left of Fit. }
  FBackBtn:= TButton.Create(Self);
  FBackBtn.Parent:= Self;
  FBackBtn.Anchors:= [akTop, akRight];
  FBackBtn.Width := 30;
  FBackBtn.Height:= FIT_BTN_H;
  FBackBtn.Top   := MARGIN;
  FBackBtn.Left:= FFitBtn.Left - 2 * (30 + MARGIN);
  FBackBtn.Caption := '<';
  FBackBtn.Hint    := 'Back -- previous graph view';
  FBackBtn.ShowHint:= True;
  FBackBtn.Enabled := False;
  FBackBtn.OnClick := BackClick;

  FFwdBtn:= TButton.Create(Self);
  FFwdBtn.Parent:= Self;
  FFwdBtn.Anchors:= [akTop, akRight];
  FFwdBtn.Width := 30;
  FFwdBtn.Height:= FIT_BTN_H;
  FFwdBtn.Top   := MARGIN;
  FFwdBtn.Left:= FFitBtn.Left - (30 + MARGIN);
  FFwdBtn.Caption := '>';
  FFwdBtn.Hint    := 'Forward -- next graph view';
  FFwdBtn.ShowHint:= True;
  FFwdBtn.Enabled := False;
  FFwdBtn.OnClick := FwdClick;

  { Vertical zoom slider - anchored right, runs top to bottom }
  FZoomBar:= TTrackBar.Create(Self);
  FZoomBar.Parent:= Self;
  FZoomBar.Anchors:= [akTop, akBottom, akRight];
  FZoomBar.Orientation:= trVertical;
  FZoomBar.Width:= ZOOM_BAR_W + 8;
  FZoomBar.Top:= MARGIN;
  FZoomBar.Left:= ClientWidth - FZoomBar.Width - MARGIN;
  FZoomBar.Height:= ClientHeight - MARGIN * 2;
  FZoomBar.Min:= 0;
  FZoomBar.Max:= 1000;
  FZoomBar.Position:= ZoomToPos(1.0);
  FZoomBar.TickStyle:= tsNone;
  FZoomBar.OnChange := ZoomBarChange;
  FSyncingZoom:= False;

  { Structure panel docked on the left: a header + a lazy tree of every unit's
    interface/implementation members.  Selecting an item shows it in the graph.
    Created before the graph so it claims the left edge; the graph takes the
    remaining client area. }
  FStructPanel:= TPanel.Create(Self);
  FStructPanel.Parent    := Self;
  FStructPanel.Align     := alLeft;
  FStructPanel.Width     := 290;
  FStructPanel.BevelOuter:= bvNone;
  FStructPanel.Color:= TColor($002A2A2A);
  FStructPanel.ParentBackground:= False;

  FStructHdr:= TPanel.Create(Self);
  FStructHdr.Parent    := FStructPanel;
  FStructHdr.Align     := alTop;
  FStructHdr.Height    := 22;
  FStructHdr.BevelOuter:= bvNone;
  FStructHdr.Color:= TColor($00383838);
  FStructHdr.ParentBackground:= False;
  FStructHdr.Font.Color:= clWhite;
  FStructHdr.Font.Style:= [fsBold];
  FStructHdr.Alignment:= taLeftJustify;
  FStructHdr.Caption  := '  Structure';

  { Search box (filters the tree to matching symbols). }
  FSearchEdit:= TEdit.Create(Self);
  FSearchEdit.Parent  := FStructPanel;
  FSearchEdit.Align   := alTop;
  FSearchEdit.TextHint:= 'Search  (ABC, MSCTYPES.Plan, TPlanType.)';
  FSearchEdit.OnChange:= SearchChanged;

  FPartialChk:= TCheckBox.Create(Self);
  FPartialChk.Parent := FStructPanel;
  FPartialChk.Align  := alTop;
  FPartialChk.Height := 20;
  FPartialChk.Caption:= 'Partial match (substring)';
  FPartialChk.Checked:= True;
  FPartialChk.Font.Color:= clWhite;
  FPartialChk.OnClick:= SearchChanged;

  { Right-click menu mirroring the graph's context actions. }
  FTreePopup:= TPopupMenu.Create(Self      );
  FMiTOpen  := TMenuItem .Create(FTreePopup);
  FMiTOpen.Caption:= 'Open Source';
  FMiTOpen.OnClick:= TreeCtxOpen;
  FTreePopup.Items.Add(FMiTOpen);
  FMiTGoto:= TMenuItem.Create(FTreePopup);
  FMiTGoto.Caption:= 'Go to Interface';
  FMiTGoto.OnClick:= TreeCtxGotoIntf;
  FTreePopup.Items.Add(FMiTGoto);
  FMiTWhere:= TMenuItem.Create(FTreePopup);
  FMiTWhere.Caption:= 'Where Used (focus)';
  FMiTWhere.OnClick:= TreeCtxWhereUsed;
  FTreePopup.Items.Add(FMiTWhere);
  FMiTCenter:= TMenuItem.Create(FTreePopup);
  FMiTCenter.Caption:= 'Show in Graph (center)';
  FMiTCenter.OnClick:= TreeCtxCenter;
  FTreePopup.Items.Add(FMiTCenter);
  FMiTFlow:= TMenuItem.Create(FTreePopup);
  FMiTFlow.Caption:= 'Trace flow from here';
  FMiTFlow.OnClick:= TreeCtxFlow;
  FTreePopup.Items.Add(FMiTFlow);

  FTree:= TTreeView.Create(Self);
  FTree.Parent       := FStructPanel;
  FTree.Align        := alClient;
  FTree.ReadOnly     := True;
  FTree.HideSelection:= False;
  FTree.RowSelect    := True;
  FTree.ShowLines    := True;
  FTree.Color:= TColor($002A2A2A);
  FTree.Font.Color:= clWhite;
  FTree.Font.Name := 'Segoe UI';
  FTree.Font.Size := 9;
  FTree.OnExpanding   := TreeExpanding;
  FTree.OnChange      := TreeChange;
  FTree.PopupMenu     := FTreePopup;
  FTree.OnContextPopup:= TreeContextPopup;

  FSplitter:= TSplitter.Create(Self);
  FSplitter.Parent := Self;
  FSplitter.Align  := alLeft; { sits at the panel's right edge }
  FSplitter.Width  := 8;      { wider grab strip -- easy to grab }
  FSplitter.Beveled:= True;   { visible grab strip }
  FSplitter.Color:= TColor($00967864);   { steel-blue accent -- clearly a control }
  FSplitter.ParentColor:= False;
  FSplitter.MinSize    := 160;
  FSplitter.ResizeStyle:= rsUpdate; { live drag }
  FSplitter.Cursor     := crHSplit; { mouse shows the resize (slider) cursor }
  FSplitter.Hint       := 'Drag to resize the search panel';
  FSplitter.ShowHint   := True;

  FGraph:= TDragLintGraphControl.Create(Self);
  FGraph.Parent           := Self;
  FGraph.Align            := alClient;
  FGraph.OnNodeClick      := GraphNodeClick;
  FGraph.OnSelectionChange:= GraphSelectionChanged;
  FGraph.OnOpenSource     := GraphOpenSource;
  FGraph.OnCrossDbJump    := GraphCrossDbJump;
  FGraph.OnTraceFlow      := GraphTraceFlow;
  FGraph.OnWhereUsed      := GraphWhereUsed;
  FGraph.OnViewChanged    := GraphViewChanged;
  FGraph.OnZoomChanged    := GraphZoomChanged;

  { "Show all units / Show top N units" toggle button anchored top-right }
  FShowAllBtn:= TButton.Create(Self);
  FShowAllBtn.Parent:= Self;
  FShowAllBtn.Anchors:= [akTop, akRight];
  FShowAllBtn.Width := 220;
  FShowAllBtn.Height:= 26;
  FShowAllBtn.Top   := 4;
  FShowAllBtn.Left:= ClientWidth - FShowAllBtn.Width - ZOOM_BAR_W - FIT_BTN_W - MARGIN * 4;
  FShowAllBtn.Caption:= '';
  FShowAllBtn.Visible:= False;
  FShowAllBtn.OnClick:= ShowAllBtnClick;

  { Flow control: same region/alignment as the graph (parent Self, alClient).
    Created AFTER FGraph so its z-order is above; toggling Visible swaps which
    of the two fills the client area between the structure dock and zoom bar. }
  FFlowControl:= TFlowChartControl.Create(Self);
  FFlowControl.Parent:= FGraph.Parent;
  FFlowControl.Align := FGraph.Align;
  FFlowControl.Visible       := False;
  FFlowControl.OnSelectSymbol:= FlowSelected;

  { "Back to Graph" and "Brief/Expanded" buttons -- top-right toolbar idiom,
    mirroring FShowAllBtn (parent Self, [akTop, akRight]).  Placed to the left
    of FShowAllBtn; hidden until flow mode is entered. }
  FFlowBtn:= TButton.Create(Self);
  FFlowBtn.Parent:= Self;
  FFlowBtn.Anchors:= [akTop, akRight];
  FFlowBtn.Width := 110;
  FFlowBtn.Height:= 26;
  FFlowBtn.Top   := 4;
  FFlowBtn.Left:= FShowAllBtn.Left - FFlowBtn.Width - MARGIN;
  FFlowBtn.Caption:= 'Back to Graph';
  FFlowBtn.Visible:= False;
  FFlowBtn.OnClick:= FlowBtnClick;

  FModeBtn:= TButton.Create(Self);
  FModeBtn.Parent:= Self;
  FModeBtn.Anchors:= [akTop, akRight];
  FModeBtn.Width := 80;
  FModeBtn.Height:= 26;
  FModeBtn.Top   := 4;
  FModeBtn.Left:= FFlowBtn.Left - FModeBtn.Width - MARGIN;
  FModeBtn.Caption:= 'Brief';
  FModeBtn.Visible:= False;
  FModeBtn.OnClick:= ModeBtnClick;

  { "Flow" button -- enters Code-Flow view from the currently selected graph
    node.  Same top-right idiom as FFlowBtn; shares FFlowBtn's slot since the
    two are never visible together (this shows in graph mode, FFlowBtn in flow
    mode).  Visible by default. }
  FEnterFlowBtn:= TButton.Create(Self);
  FEnterFlowBtn.Parent:= Self;
  FEnterFlowBtn.Anchors:= [akTop, akRight];
  FEnterFlowBtn.Width := 70;
  FEnterFlowBtn.Height:= 26;
  FEnterFlowBtn.Top   := 4;
  FEnterFlowBtn.Left:= FShowAllBtn.Left - FEnterFlowBtn.Width - MARGIN;
  FEnterFlowBtn.Caption:= 'Flow';
  FEnterFlowBtn.Visible:= True;
  FEnterFlowBtn.OnClick:= EnterFlowBtnClick;
end; // procedure

{ ---------------------------------------------------------------------------- }
{ resolve-dbs shell-out (manifest-driven DB selection when no --db given)     }
{ ---------------------------------------------------------------------------- }

// v0.45 Task 10: locate the drag-lint engine executable.
// Lookup order:
//   1. drag-lint.exe beside THIS executable (preferred for installed setups).
//   2. Fallback: <ExeDir>\..\..\..\Delphi-RAG-lint\third_party\dll-win64\drag-lint.exe
//      (development layout: Delphi-RAG-Lint-Graph lives next to Delphi-RAG-lint).
// Returns '' when no candidate is found on disk.
/// <summary>Finds the drag-lint.exe engine used to run the resolve-dbs command.
/// Returns an empty string when no candidate exists on disk.</summary>
/// <remarks>Not thread-safe; call from the owning (main) thread only.</remarks>
function TfrmMain.ResolveEngineExe: string;
var
  ExeDir   : string;
  Candidate: string;
begin
  ExeDir:= ExtractFilePath(ParamStr(0));

  // 1. Beside the graph viewer executable.
  Candidate:= TPath.Combine(ExeDir, 'drag-lint.exe');
  if TFile.Exists(Candidate) then Exit(Candidate);

  // 2. Development layout: ../../../Delphi-RAG-lint/third_party/dll-win64/
  Candidate:= TPath.GetFullPath( TPath.Combine(ExeDir, '..\..\..\Delphi-RAG-lint\third_party\dll-win64\drag-lint.exe'));
  if TFile.Exists(Candidate) then Exit(Candidate);

  Result:= '';
end;

// v0.45 Task 10: spawn AExe with AArgs (a single command-line string, already
// quoted), capture stdout, and return it as a string.  Returns '' on any error.
// CloseHandle is called for all kernel objects regardless of outcome.
/// <summary>Spawns AExe with the given argument string and returns the captured
/// stdout.  Returns an empty string on spawn failure or empty output.</summary>
/// <param name="AExe">Full path to the executable; must be quoted if it
///   contains spaces.</param>
/// <param name="AArgs">Full argument string to append after AExe.</param>
/// <returns>Captured stdout text, or '' on error.</returns>
/// <remarks>Not thread-safe; call from the owning (main) thread only.</remarks>
function TfrmMain.SpawnCaptureStdout(const AExe, AArgs: string): string;
const
  PIPE_BUF = 4096;
var
  SA        : TSecurityAttributes               ;
  hReadPipe : THandle                           ;
  hWritePipe: THandle                           ;
  SI        : TStartupInfo                      ;
  PI        : TProcessInformation               ;
  CmdLine   : string                            ;
  Buf       : array[0..PIPE_BUF - 1] of AnsiChar;
  BytesRead : DWORD                             ;
begin
  Result    := '';
  hReadPipe := 0;
  hWritePipe:= 0;
  PI.hProcess:= 0;
  PI.hThread := 0;

  // Create anonymous pipe for stdout capture.
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength:= SizeOf(SA);
  SA.bInheritHandle:= True;
  if not CreatePipe(hReadPipe, hWritePipe, @SA, 0) then Exit;

  try
    // Make the read end non-inheritable so the child doesn't hold it open.
    SetHandleInformation(hReadPipe, HANDLE_FLAG_INHERIT, 0);

    FillChar(SI, SizeOf(SI), 0);
    SI.cb:= SizeOf(SI);
    SI.dwFlags:= STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    SI.wShowWindow:= SW_HIDE;
    SI.hStdOutput := hWritePipe;
    SI.hStdError:= GetStdHandle(STD_ERROR_HANDLE);
    SI.hStdInput:= GetStdHandle(STD_INPUT_HANDLE);

    CmdLine:= '"' + AExe + '" ' + AArgs;
    // CreateProcess needs a mutable buffer.
    var MutableCmd:= CmdLine;
    UniqueString(MutableCmd);

    if not CreateProcess(nil, PChar(MutableCmd), nil, nil, True, CREATE_NO_WINDOW, nil, nil, SI, PI) then Exit;

    // Close the write end in the parent: once the child closes its handle the
    // read end will signal EOF.
    CloseHandle(hWritePipe);
    hWritePipe:= 0;

    // Read all stdout. Each ReadFile call may return a partial buffer;
    // accumulate via RawByteString to handle the exact byte count.
    var Raw: RawByteString;
    Raw:= '';
    while ReadFile(hReadPipe, Buf[0], PIPE_BUF, BytesRead, nil) and (BytesRead > 0) do
    begin
      SetLength(Raw, Length(Raw) + Integer(BytesRead));
      Move(Buf[0], Raw[Length(Raw) - Integer(BytesRead) + 1], BytesRead);
    end;
    Result:= string(Raw);

    WaitForSingleObject(PI.hProcess, INFINITE);
  finally
    if hWritePipe <> 0 then CloseHandle(hWritePipe);
    CloseHandle(hReadPipe);
    if PI.hProcess <> 0 then CloseHandle(PI.hProcess);
    if PI.hThread  <> 0 then CloseHandle(PI.hThread );
  end; // try
end; // function

// v0.45 Task 10: when the viewer was launched with no --db flags, shell out to
// drag-lint.exe resolve-dbs --json [--platform <p>] to obtain the manifest-driven
// DB list.  Parses the JSON array and populates FDbPaths.
// On any error (engine not found, spawn failure, empty/invalid JSON) the method
// returns without modifying FDbPaths; RunLoad's existing "no DB" fallback then
// shows the prompt message -- no crash.
/// <summary>Populates FDbPaths by spawning drag-lint resolve-dbs when no
/// explicit --db flags were given.  Does nothing on error; RunLoad's fallback
/// message is shown instead.</summary>
/// <remarks>Not thread-safe; call from the owning (main) thread only.</remarks>
procedure TfrmMain.ResolveDbsFromEngine;
var
  EngineExe: string    ;
  PlatArg  : string    ;
  RawOutput: string    ;
  J        : TJSONValue;
  JArr     : TJSONArray;
  K        : Integer   ;
  Count    : Integer   ;
  Path     : string    ;
begin
  EngineExe:= ResolveEngineExe;
  if EngineExe = '' then Exit; // No engine found; fall through to RunLoad's prompt.

  // Build argument string: resolve-dbs --json [--platform <p>]
  PlatArg:= '';
  if FPlatform <> '' then PlatArg:= ' --platform ' + FPlatform;
  RawOutput:= SpawnCaptureStdout(EngineExe, 'resolve-dbs --json' + PlatArg);
  if RawOutput = '' then Exit;

  // Parse JSON array: ["path1","path2",...]
  J:= TJSONObject.ParseJSONValue(RawOutput.Trim);
  if J = nil then Exit;
  try
    if not (J is TJSONArray) then Exit;
    JArr:= TJSONArray(J);
    Count:= JArr.Count;
    if Count = 0 then Exit;
    SetLength(FDbPaths, Count);
    for K:= 0 to Count - 1 do
    begin
      Path:= JArr.Items[K].Value;
      FDbPaths[K]:= Path;
    end;
  finally
    J.Free;
  end; // try
end; // procedure

procedure TfrmMain.ParseDbArgs;
var
  I    : Integer;
  S    : string ;
  Count: Integer;
begin
  Count:= 0;
  SetLength(FDbPaths, 0);
  FPlatform:= '';
  I        := 1;
  while I <= ParamCount do
  begin
    S:= ParamStr(I);
    if (LowerCase(S) = '--db') and (I < ParamCount) then
    begin
      SetLength(FDbPaths, Count + 1);
      FDbPaths[Count]:= ParamStr(I + 1);
      Inc(Count);
      Inc(I, 2);
    end
    else if (LowerCase(S) = '--platform') and (I < ParamCount) then
    begin
      FPlatform:= ParamStr(I + 1);
      Inc(I, 2);
    end
    else Inc(I);
  end; // while

  // When no explicit --db flags: try manifest-driven DB selection via the engine.
  if Length(FDbPaths) = 0 then ResolveDbsFromEngine;
end; // procedure

procedure TfrmMain.FormShow(Sender: TObject);
begin
  if not FLoaded then
  begin
    FLoaded:= True;
    PostMessage(Handle, WM_LOADGRAPH, 0, 0);
    PublishViewerHwnd(True);   { v0.49: discoverable by the IDE plugin (editor-sync) }
  end;
end;

procedure TfrmMain.PublishViewerHwnd(APublish: Boolean);
const
  KEY  = 'Software\DragLint';
  NAME = 'GraphViewerHwnd';
var
  Reg: TRegistry;
begin
  { Best-effort: never let registry I/O disturb the viewer. The plugin reads this
    value, validates with IsWindow, and idles when it is absent/stale. }
  try
    Reg:= TRegistry.Create(KEY_READ or KEY_WRITE);
    try
      Reg.RootKey:= HKEY_CURRENT_USER;
      if APublish then
      begin
        if Reg.OpenKey(KEY, True) then
          Reg.WriteInteger(NAME, Integer(Handle));   { HWNDs fit in 32 bits }
      end
      else if Reg.OpenKey(KEY, False) then
      begin
        { only clear if WE are the registered viewer (don't clobber another) }
        if Reg.ValueExists(NAME) and (Reg.ReadInteger(NAME) = Integer(Handle)) then
          Reg.DeleteValue(NAME);
      end;
    finally
      Reg.Free;
    end;
  except
  end;
end;

procedure TfrmMain.WMLoadGraph(var Msg: TMessage);
begin
  RunLoad;
  { Standalone only -- yanking foreground while embedded would steal focus
    from the IDE. }
  if FParentHwnd = 0 then SetForegroundWindow(Handle);
  { v0.49: automation/self-test entry. --flow <qname> jumps into the flow view;
    --whereused <qname> fills the caller list. --selftest <file> then writes a
    one-line diagnostic and exits. Deferred one turn so layout/paint settle. }
  if (GetParamValue('--flow') <> '') or (GetParamValue('--whereused') <> '') then
    PostMessage(Handle, WM_SELFTEST, 0, 0);
end;

procedure TfrmMain.WMSelfTest(var Msg: TMessage);
var
  FlowSym, UsedBySym, LogPath, Diag: string;
begin
  FlowSym  := GetParamValue('--flow');
  UsedBySym:= GetParamValue('--whereused');
  if FlowSym <> '' then StartFlowFrom(FlowSym);
  if UsedBySym <> '' then ShowUsedBy(UsedBySym);

  LogPath:= GetParamValue('--selftest');
  if LogPath <> '' then
  begin
    if FlowSym <> '' then
      Diag:= 'symbol=' + FlowSym + #13#10 + FFlowControl.DiagDump
    else
      Diag:= 'symbol=' + UsedBySym + #13#10 +
             Format('usedby callers=%d', [FTree.Items.Count]);
    try
      TFile.WriteAllText(LogPath, Diag + #13#10, TEncoding.ASCII);
    except
      { never let diagnostics crash the viewer }
    end;
    Application.Terminate;   { headless self-test run -> exit }
  end;
end;

procedure TfrmMain.RunLoad;
begin
  { --- create VM --- }
  FVM:= TGraphViewModel.Create;

  if Length(FDbPaths) = 0 then
  begin
    FGraph.Bind(FVM);
    FStatus.SimpleText:= 'Pass --db <drag-lint.sqlite> to load a graph.';
    UpdateShowAllButton;
    Exit;
  end;

  { --- build catalog and open store 0 --- }
  FCatalog:= TDbCatalog.Create(FDbPaths);
  FVM.SetCatalog(FCatalog);

  try
    FVM.OpenStore(0);
  except
    on E: Exception do
    begin
      FGraph.Bind(FVM);
      FStatus.SimpleText:= 'Error opening store 0: ' + E.message;
      UpdateShowAllButton;
      Exit;
    end;
  end;

  FGraph.Bind(FVM);

  if FVM.Data.NodeCount = 0 then FStatus.SimpleText:= 'Pass --db <drag-lint.sqlite> to load a graph.'
  else FStatus.SimpleText:= Format(
    'Loaded %s: %d nodes  |  Click a unit/class to expand  -  ' + 'click a method to open source  -  Shift+click to focus  -  ' + 'double-click to drill in  -  Backspace = back',
    [ExtractFileName(FDbPaths[0]), FVM.Data.NodeCount]);

  { Force a projection pass so FHiddenTopLevelCount is current before
    UpdateShowAllButton reads it -- Bind only schedules a paint. }
  FVM.Projection;
  UpdateShowAllButton;
  UpdateBreadcrumbs;
  BuildStructureRoots;
end; // procedure

{ ---- structure panel ----------------------------------------------------- }

function TfrmMain.CategoryOf(AKind: TGraphNodeKind): Integer;
begin
  case AKind of
    nkClass, nkInterface, nkRecord, nkType: Result:= 0; { Types }
    nkConst : Result:= 1; { Consts }
    nkVar   : Result:= 2; { Vars }
    nkProcedure, nkFunction               : Result:= 3; { Routines }
    else Result:= 4; { Other }
  end;
end;

function TfrmMain.NewTag(AKind: TStructKind; const AGraphId, ASection: string; ACat: Integer): TStructTag;
begin
  Result:= TStructTag.Create;
  Result.Kind   := AKind;
  Result.GraphId:= AGraphId;
  Result.Section:= ASection;
  Result.Cat    := ACat;
  FStructTags.Add(Result);
end;

procedure TfrmMain.ClearStructure;
begin
  FTree.Items.Clear; { frees TTreeNodes; their .Data tags are owned by
                             FStructTags and survive -- cleared next line }
  FStructTags.Clear;
end;

procedure TfrmMain.BuildStructureRoots;
var
  I    : Integer       ;
  Units: TList<Integer>;
  N    : PGraphNode    ;
  TN   : TTreeNode     ;
  Dummy: TTreeNode     ;
begin
  if (FVM = nil) or (FVM.Data = nil) then Exit;
  ClearStructure;
  FTree.Items.BeginUpdate;
  try
    Units:= TList<Integer>.Create;
    try
      for I:= 0 to FVM.Data.NodeCount - 1 do
        if FVM.Data.NodeAt(I).Kind = nkUnit then Units.Add(I);
      { alphabetical by unit name }
      Units.Sort(TComparer<Integer>.Construct( function(const A, B: Integer): Integer begin Result:= CompareText(FVM.Data.NodeAt(A).Label_, FVM.Data.NodeAt(B).Label_); end));

      for I in Units do
      begin
        N:= FVM.Data.NodeAt(I);
        TN:= FTree.Items.AddChild(nil, N.Label_);
        TN.Data:= NewTag(skUnit, N.Id, '', 0);
        Dummy:= FTree.Items.AddChild(TN, ''); { lazy: expand to populate }
        Dummy.Data:= nil;
      end;
    finally
      Units.Free;
    end; // try
  finally
    FTree.Items.EndUpdate;
  end; // try
  FStructHdr.Caption:= Format('  Structure  (%d units)', [FTree.Items.Count]);
end; // procedure

procedure TfrmMain.TreeExpanding(Sender: TObject; Node: TTreeNode; var AllowExpansion: Boolean);
const
  CAT_NAMES: array[0..4] of string = ('Types', 'Consts', 'Vars', 'Routines', 'Other');
var
  Tag     : TStructTag            ;
  ChildTag: TStructTag            ;
  UnitIdx : Integer               ;
  SymIdx  : Integer               ;
  Ci      : Integer               ;
  c       : Integer               ;
  Ui      : Integer               ;
  Kids    : TArray<Integer>       ;
  M       : PGraphNode            ;
  Sect    : string                ;
  Cap     : string                ;
  Glyph   : string                ;
  HasIntf : Boolean               ;
  HasImpl : Boolean               ;
  CatCount: array[0..4] of Integer;
  Order   : TList<Integer>        ;
  TN      : TTreeNode             ;
  Dummy   : TTreeNode             ;
  UIntf   : TArray<TUnitUseRow>   ;
  UImpl   : TArray<TUnitUseRow>   ;
  UseArr  : TArray<TUnitUseRow>   ;
  UBy     : TArray<string>        ;

  function SectOf(AIdx: Integer): string;
  begin
    Result:= FVM.Data.NodeAt(AIdx).Section;
    if Result = '' then Result:= 'interface';
  end;

  function IsSectionMarker(AIdx: Integer): Boolean;
  var
    KT: string;
  begin
    KT:= FVM.Data.NodeAt(AIdx).KindText;
    Result:= (KT = 'initialization') or (KT = 'finalization');
  end;

  function AddNode(const ACaption: string; ATag: TStructTag; AExpandable: Boolean): TTreeNode;
  begin
    Result:= FTree.Items.AddChild(Node, ACaption);
    Result.Data:= ATag;
    if AExpandable then
    begin
      Dummy:= FTree.Items.AddChild(Result, '');
      Dummy.Data:= nil;
    end;
  end;

begin
  AllowExpansion:= True;
  Tag:= TStructTag(Node.Data);
  if (Tag = nil) or Tag.Populated then Exit;
  if FVM = nil then Exit;

  { drop the lazy dummy child(ren) }
  while Node.Count > 0 do Node.Item[0].Delete;
  Tag.Populated:= True;

  case Tag.Kind of
    skUnit:
    begin
      UnitIdx:= FVM.Data.FindNodeIndex(Tag.GraphId);
      if UnitIdx < 0 then Exit;
      Kids:= FVM.Data.ChildrenOf(UnitIdx);
      HasIntf:= False; HasImpl:= False;
      for Ci in Kids do
      begin
        if IsSectionMarker(Ci) then Continue; { init/final shown separately }
        if SectOf(Ci) = 'implementation' then HasImpl:= True
        else HasIntf:= True;
      end;
      if HasIntf then AddNode('Interface'     , NewTag(skSection, Tag.GraphId, 'interface'     , 0), True);
      if HasImpl then AddNode('Implementation', NewTag(skSection, Tag.GraphId, 'implementation', 0), True);
      { initialization / finalization markers (v0.41 scanner) as their own
          unit-level leaves -- click to jump to the section in the graph. }
      for Ci in Kids do
      begin
        M:= FVM.Data.NodeAt(Ci);
        if M.KindText      = 'initialization' then AddNode('Initialization', NewTag(skSymbol, M.Id, '', 0), False)
        else if M.KindText = 'finalization' then AddNode('Finalization', NewTag(skSymbol, M.Id, '', 0), False);
      end;
      { Uses-in / Used-by from the unit_uses table (exact, queried on demand). }
      if Length(FDbPaths) > 0 then
      begin
        if QueryUnitUses(FDbPaths[0], Tag.GraphId, UIntf, UImpl, UBy) then
        begin
          if Length(UIntf) > 0 then AddNode(Format('Uses - interface (%d)', [Length(UIntf)]), NewTag(skUsesIntf, Tag.GraphId, '', 0), True);
          if Length(UImpl) > 0 then AddNode(Format('Uses - implementation (%d)', [Length(UImpl)]), NewTag(skUsesImpl, Tag.GraphId, '', 0), True);
          if Length(UBy) > 0 then AddNode(Format('Used by (%d)', [Length(UBy)]), NewTag(skUsedBy, Tag.GraphId, '', 0), True);
        end;
      end;
    end; // case

    skUsesIntf, skUsesImpl:
    begin
      if Length(FDbPaths) = 0 then Exit;
      if not QueryUnitUses(FDbPaths[0], Tag.GraphId, UIntf, UImpl, UBy) then Exit;
      if Tag.Kind = skUsesImpl then UseArr:= UImpl else UseArr:= UIntf;
      for Ui:= 0 to High(UseArr) do
      begin
        Cap:= UseArr[Ui].UnitName;
        if UseArr[Ui].External then Cap:= Cap + '   (external)';
        { leaf: skUnit tag -> clicking centers that unit in the graph if it
            is in the loaded store (external/library units just no-op). }
        AddNode(Cap, NewTag(skUnit, UseArr[Ui].UnitName, '', 0), False);
      end;
    end;

    skUsedBy:
    begin
      if Length(FDbPaths) = 0 then Exit;
      if not QueryUnitUses(FDbPaths[0], Tag.GraphId, UIntf, UImpl, UBy) then Exit;
      for Ui:= 0 to High(UBy) do AddNode(UBy[Ui], NewTag(skUnit, UBy[Ui], '', 0), False);
    end;

    skSection:
    begin
      UnitIdx:= FVM.Data.FindNodeIndex(Tag.GraphId);
      if UnitIdx < 0 then Exit;
      Kids:= FVM.Data.ChildrenOf(UnitIdx);
      FillChar(CatCount, SizeOf(CatCount), 0);
      for Ci in Kids do
        if (SectOf(Ci) = Tag.Section) and not IsSectionMarker(Ci) then Inc(CatCount[CategoryOf(FVM.Data.NodeAt(Ci).Kind)]);
      for c:= 0 to 4 do
        if CatCount[c] > 0 then AddNode(Format('%s (%d)', [CAT_NAMES[c], CatCount[c]]), NewTag(skCategory, Tag.GraphId, Tag.Section, c), True);
    end;

    skCategory:
    begin
      UnitIdx:= FVM.Data.FindNodeIndex(Tag.GraphId);
      if UnitIdx < 0 then Exit;
      Kids:= FVM.Data.ChildrenOf(UnitIdx);
      Order:= TList<Integer>.Create;
      try
        for Ci in Kids do
          if (SectOf(Ci) = Tag.Section) and not IsSectionMarker(Ci) and (CategoryOf(FVM.Data.NodeAt(Ci).Kind) = Tag.Cat) then Order.Add(Ci);
        Order.Sort(TComparer<Integer>.Construct( function(const A, B: Integer): Integer begin Result:= CompareText(FVM.Data.NodeAt(A).Label_, FVM.Data.NodeAt(B).Label_); end));
        for Ci in Order do
        begin
          M:= FVM.Data.NodeAt(Ci);
          Cap:= M.Label_;
          if (M.Kind = nkType) and (M.KindText <> '') then Cap:= Cap + '  : ' + M.KindText;
          ChildTag:= NewTag(skSymbol, M.Id, '', 0);
          ChildTag.IsType:= Length(FVM.Data.ChildrenOf(Ci)) > 0;
          AddNode(Cap, ChildTag, ChildTag.IsType);
        end;
      finally
        Order.Free;
      end; // try
    end; // begin

    skSymbol:
    begin
      SymIdx:= FVM.Data.FindNodeIndex(Tag.GraphId);
      if SymIdx < 0 then Exit;
      Kids:= FVM.Data.ChildrenOf(SymIdx);
      Order:= TList<Integer>.Create;
      try
        for Ci in Kids do Order.Add(Ci);
        Order.Sort(TComparer<Integer>.Construct(
            function(const A, B: Integer): Integer var KA, KB: Integer; begin KA:= Ord(FVM.Data.NodeAt(A).Kind); KB:= Ord(FVM.Data.NodeAt(B).Kind); if KA <> KB then Exit(KA
              - KB); Result:= CompareText(FVM.Data.NodeAt(A).Label_, FVM.Data.NodeAt(B).Label_); end
          ));
        for Ci in Order do
        begin
          M:= FVM.Data.NodeAt(Ci);
          Glyph:= VisibilityGlyph(M.Modifiers);
          if Glyph <> '' then Glyph:= Glyph + ' ';
          Cap:= Glyph + M.Label_;
          if M.Signature <> '' then Cap:= Cap + ': ' + M.Signature;
          ChildTag:= NewTag(skSymbol, M.Id, '', 0);
          ChildTag.IsType:= Length(FVM.Data.ChildrenOf(Ci)) > 0;
          TN:= AddNode(Cap, ChildTag, ChildTag.IsType);
          if TN = nil then ;
        end;
      finally
        Order.Free;
      end; // try
    end; // begin
  end; // case
end; // begin

procedure TfrmMain.TreeChange(Sender: TObject; Node: TTreeNode);
var
  Tag: TStructTag;
begin
  if FSyncingTree or (Node = nil) or (FGraph = nil) then Exit;
  Tag:= TStructTag(Node.Data);
  if (Tag = nil) or (Tag.GraphId = '') then Exit;
  if not (Tag.Kind in [skUnit, skSymbol]) then Exit;
  { Show the selected item in the graph (reveal + center). }
  FSyncingTree:= True;
  try
    NavTo(Tag.GraphId); { v0.48: center + record in nav history }
  finally
    FSyncingTree:= False;
  end;
end;

{ ---- search ---- }

procedure TfrmMain.SearchChanged(Sender: TObject);
begin
  DoSearch;
end;

procedure TfrmMain.DoSearch;
var
  Term: string;
begin
  if FVM = nil then Exit;
  Term:= Trim(FSearchEdit.Text);
  if Term = '' then BuildStructureRoots
  else BuildSearchResults(Term, FPartialChk.Checked);
end;

{ ---- v0.49: graph navigation history (unified, ViewModel-backed) ---- }

{ The ViewModel owns ONE back/forward history. Every move pushes an entry --
  search/tree select, context Center, double-click, drill-in, level-up
  (breadcrumb), cross-DB jump, editor-sync. NavTo just reveals + centers
  (CenterOnNode records the entry); Back/Forward (buttons, mouse thumb buttons,
  Backspace) traverse it via the control. }
procedure TfrmMain.NavTo(const AGraphId: string);
begin
  if (FGraph = nil) or (AGraphId = '') then Exit;
  FGraph.CenterOnNode(AGraphId);
  UpdateNavButtons;
end;

procedure TfrmMain.BackClick(Sender: TObject);
begin
  if FGraph <> nil then FGraph.NavigateBack;
  UpdateNavButtons;
end;

procedure TfrmMain.FwdClick(Sender: TObject);
begin
  if FGraph <> nil then FGraph.NavigateForward;
  UpdateNavButtons;
end;

procedure TfrmMain.UpdateNavButtons;
begin
  if FBackBtn <> nil then FBackBtn.Enabled:= (FVM <> nil) and FVM.CanGoBack;
  if FFwdBtn  <> nil then FFwdBtn.Enabled := (FVM <> nil) and FVM.CanGoForward;
end;

{ ---- v0.48: editor-sync (IDE -> graph) ---- }

{ Map an editor symbol/unit name to the id of the best-matching graph node, or ''
  if none. The plugin may send a unit name ("MSCTYPES"), a qualified symbol
  ("MSCTYPES.TPlanType") or a bare leaf ("TPlanType"); we score candidates so the
  most specific match wins. Mirrors the search-box matching (BuildSearchResults). }
function TfrmMain.ResolveSymbolToGraphId(const ASymbol: string): string;
var
  I        : Integer   ;
  DotP     : Integer   ;
  BestScore: Integer   ;
  Score    : Integer   ;
  Scope    : string    ;
  Leaf     : string    ;
  Sym      : string    ;
  N        : PGraphNode;
begin
  Result:= '';
  if (FVM = nil) or (FVM.Data = nil) then Exit;
  Sym:= Trim(ASymbol);
  if Sym = '' then Exit;

  DotP:= LastDelimiter('.', Sym);
  if DotP > 0 then
  begin
    Scope:= Copy(Sym, 1, DotP - 1);
    Leaf:= Copy(Sym, DotP + 1, MaxInt);
  end
  else
  begin
    Scope:= '';
    Leaf := Sym;
  end;

  BestScore:= 0;
  for I:= 0 to FVM.Data.NodeCount - 1 do
  begin
    N:= FVM.Data.NodeAt(I);
    if (N.Kind = nkProject) or (N.Id = '@project') then Continue;

    if SameText(N.Id, Sym) then Score:= 100 { exact qualified id }
    else if SameText(N.Label_, Leaf) and ((Scope = '') or ContainsText(N.Id, Scope)) then Score:= 60 { leaf name within scope }
    else if (N.Kind = nkUnit) and SameText(N.Label_, Sym) then Score:= 50 { unit matched by name }
    else if ContainsText(N.Id, Sym) then Score:= 20 { id substring fallback }
    else Score:= 0;

    if Score > BestScore then
    begin
      BestScore:= Score;
      Result:= N.Id;
      if Score = 100 then Exit; { cannot do better }
    end;
  end; // for
end; // function

{ The IDE plugin posts the active editor's unit/symbol here on tab-switch so the
  graph follows the editor. Resolve + center via NavTo (records history, so the
  Back button undoes an editor-driven jump). Ignores anything not addressed to us
  (dwData magic) and unknown symbols (status hint only -- never disrupts the view). }
procedure TfrmMain.WMCopyData(var Msg: TWMCopyData);
var
  A  : AnsiString;
  Sym: string    ;
  Gid: string    ;
begin
  Msg.Result:= 0;
  if Msg.CopyDataStruct = nil then Exit;
  if Msg.CopyDataStruct.dwData <> CD_CENTER_SYMBOL then Exit;
  if (Msg.CopyDataStruct.lpData = nil) or (Msg.CopyDataStruct.cbData = 0) then Exit;

  SetString(A, PAnsiChar(Msg.CopyDataStruct.lpData), Msg.CopyDataStruct.cbData);
  { tolerate a trailing NUL whether or not the sender counted it in cbData }
  while (Length(A) > 0) and (A[Length(A)] = #0) do SetLength(A, Length(A) - 1);
  Sym:= Trim(string(A));
  if (Sym = '') or (FVM = nil) then Exit;

  Gid:= ResolveSymbolToGraphId(Sym);
  if Gid <> '' then
  begin
    NavTo(Gid);
    Msg.Result:= 1; { resolved + centered }
  end
  else if FStatus <> nil then FStatus.SimpleText:= Format('Editor sync: "%s" is not in this graph.', [Sym]);
end; // procedure

function TfrmMain.UnitNameOf(ANodeIdx: Integer): string;
var
  Idx  : Integer   ;
  Guard: Integer   ;
  N    : PGraphNode;
begin
  Result:= '';
  Idx   := ANodeIdx;
  Guard := 0;
  while (Idx >= 0) and (Guard < 64) do
  begin
    N:= FVM.Data.NodeAt(Idx);
    if N.Kind = nkUnit then Exit(N.Label_);
    Idx:= FVM.Data.ParentIndexOf(Idx);
    Inc(Guard);
  end;
end;

procedure TfrmMain.BuildSearchResults(const ATerm: string; APartial: Boolean);
const
  MAX_RESULTS = 1000;
var
  I      : Integer       ;
  DotP   : Integer       ;
  Scope  : string        ;
  Leaf   : string        ;
  Cap    : string        ;
  KindS  : string        ;
  N      : PGraphNode    ;
  Matches: TList<Integer>;
  ScopeOk: Boolean       ;
  LeafOk : Boolean       ;
  TN     : TTreeNode     ;
  Capped : Boolean       ;
begin
  { "Unit.Type.leaf" -> scope = before last dot (matched against the qualified
    name), leaf = after (matched against the symbol's own name).  No dot ->
    match the name only.  Trailing dot -> everything in that scope. }
  DotP:= LastDelimiter('.', ATerm);
  if DotP > 0 then
  begin
    Scope:= Copy(ATerm, 1, DotP - 1);
    Leaf:= Copy(ATerm, DotP + 1, MaxInt);
  end
  else
  begin
    Scope:= '';
    Leaf := ATerm;
  end;

  ClearStructure;
  Matches:= TList<Integer>.Create;
  Capped:= False;
  try
    for I:= 0 to FVM.Data.NodeCount - 1 do
    begin
      N:= FVM.Data.NodeAt(I);
      if (N.Kind = nkProject) or (N.Id = '@project') then Continue;

      if Scope = '' then ScopeOk:= True
      else ScopeOk:= ContainsText(N.Id, Scope);
      if not ScopeOk then Continue;

      if Leaf = '' then LeafOk:= True
      else if APartial then LeafOk:= ContainsText(N.Label_, Leaf)
      else LeafOk:= SameText(N.Label_, Leaf);
      if not LeafOk then Continue;

      Matches.Add(I);
      if Matches.Count >= MAX_RESULTS then begin Capped:= True; Break; end;
    end; // for

    Matches.Sort(TComparer<Integer>.Construct(
        function(const A, B: Integer): Integer
        begin
          Result:= CompareText(FVM.Data.NodeAt(A).Label_, FVM.Data.NodeAt(B).Label_);
          if Result = 0 then Result:= CompareText(FVM.Data.NodeAt(A).Id, FVM.Data.NodeAt(B).Id);
        end));

    FTree.Items.BeginUpdate;
    try
      for I in Matches do
      begin
        N:= FVM.Data.NodeAt(I);
        KindS:= N.KindText;
        if KindS = '' then KindS:= '?';
        Cap:= N.Label_ + '   : ' + KindS + '   (' + UnitNameOf(I) + ')';
        TN:= FTree.Items.AddChild(nil, Cap);
        TN.Data:= NewTag(skSymbol, N.Id, '', 0);
      end;
    finally
      FTree.Items.EndUpdate;
    end;

    if Capped then FStructHdr.Caption:= Format('  Search: %d+ results (capped)', [Matches.Count])
    else FStructHdr.Caption:= Format('  Search: %d result(s)', [Matches.Count]);
  finally
    Matches.Free;
  end; // try
end; // procedure

{ ---- tree context menu (mirrors the graph's right-click actions) ---- }

procedure TfrmMain.TreeContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
var
  Node: TTreeNode ;
  Tag : TStructTag;
  PN  : PGraphNode;
begin
  Handled:= False;
  if (MousePos.X < 0) or (MousePos.Y < 0) then Node:= FTree.Selected
  else Node:= FTree.GetNodeAt(MousePos.X, MousePos.Y);
  if Node = nil then begin Handled:= True; Exit; end;

  FTree.Selected:= Node; { also drives TreeChange -> graph selection }
  Tag:= TStructTag(Node.Data);
  if (Tag = nil) or (Tag.GraphId = '') or not (Tag.Kind in [skUnit, skSymbol]) then
  begin
    Handled:= True; { group node -> no menu }
    Exit;
  end;

  FTreeCtxId:= Tag.GraphId;
  PN:= FVM.Data.FindNode(FTreeCtxId);
  FMiTOpen.Enabled:= (PN <> nil) and (PN.FilePath <> '');
end; // procedure

procedure TfrmMain.TreeCtxOpen(Sender: TObject);
var
  PN: PGraphNode;
begin
  if FVM = nil then Exit;
  PN:= FVM.Data.FindNode(FTreeCtxId);
  if PN <> nil then GraphOpenSource(Self, PN);
end;

procedure TfrmMain.TreeCtxGotoIntf(Sender: TObject);
begin
  if FGraph <> nil then FGraph.GoToInterfaceFor(FTreeCtxId);
end;

procedure TfrmMain.TreeCtxWhereUsed(Sender: TObject);
begin
  ShowUsedBy(FTreeCtxId);   { precise caller list in the panel }
end;

procedure TfrmMain.TreeCtxCenter(Sender: TObject);
begin
  NavTo(FTreeCtxId); { v0.48: center + record in nav history }
end;

{ ---- flow mode ---------------------------------------------------------- }

procedure TfrmMain.TreeCtxFlow(Sender: TObject);
begin
  if FTreeCtxId <> '' then StartFlowFrom(FTreeCtxId);
end;

procedure TfrmMain.GraphTraceFlow(Sender: TObject; const AId: string);
begin
  if AId <> '' then StartFlowFrom(AId);
end;

procedure TfrmMain.GraphWhereUsed(Sender: TObject; const AId: string);
begin
  ShowUsedBy(AId);
end;

procedure TfrmMain.ShowUsedBy(const ASymbolId: string);
var
  Callers: TArray<TCallerRow>;
  Row    : TCallerRow        ;
  Cap    : string            ;
  Leaf   : string            ;
  Scope  : string            ;
  P      : Integer           ;
  TN     : TTreeNode         ;
  DbPath : string            ;
begin
  if (FVM = nil) or (ASymbolId = '') or (Length(FDbPaths) = 0) then Exit;

  { Query the active store's DB by NAME (the loaded graph's call edges only cover
    RESOLVED calls, so they miss most callers). }
  if (FVM.ActiveStoreIndex >= 0) and (FVM.ActiveStoreIndex < Length(FDbPaths)) then
    DbPath:= FDbPaths[FVM.ActiveStoreIndex]
  else
    DbPath:= FDbPaths[0];
  if not QuerySymbolCallers(DbPath, ASymbolId, Callers) then SetLength(Callers, 0);

  ClearStructure;
  FTree.Items.BeginUpdate;
  try
    for Row in Callers do
    begin
      P:= LastDelimiter('.', Row.QualifiedName);
      if P > 0 then
      begin
        Leaf := Copy(Row.QualifiedName, P + 1, MaxInt);
        Scope:= Copy(Row.QualifiedName, 1, P - 1);
      end
      else begin Leaf:= Row.QualifiedName; Scope:= ''; end;
      Cap:= Leaf + '   : ' + Row.KindText;
      if Scope <> '' then Cap:= Cap + '   (' + Scope + ')';
      TN:= FTree.Items.AddChild(nil, Cap);
      TN.Data:= NewTag(skSymbol, Row.QualifiedName, '', 0);   { click -> jump to caller }
    end;
  finally
    FTree.Items.EndUpdate;
  end;

  P:= LastDelimiter('.', ASymbolId);
  if P > 0 then Leaf:= Copy(ASymbolId, P + 1, MaxInt) else Leaf:= ASymbolId;
  FStructHdr.Caption:= Format('  Used by %s: %d caller(s)', [Leaf, Length(Callers)]);
  if FStatus <> nil then
    FStatus.SimpleText:= Format('%d caller(s) of %s  (click a row to jump)', [Length(Callers), ASymbolId]);

  { Keep the graph readable: just center on the symbol -- no all-units hairball. }
  if FGraph <> nil then FGraph.CenterOnNode(ASymbolId);
end;

procedure TfrmMain.EnterFlowBtnClick(Sender: TObject);
begin
  if FSelectedGraphId <> '' then StartFlowFrom(FSelectedGraphId)
  else FStatus.SimpleText:= 'Select a graph node first, then click Flow.';
end;

procedure TfrmMain.StartFlowFrom(const ASymbolId: string);
begin
  if (FCatalog = nil) or (ASymbolId = '') then Exit;
  if FFlowSource  = nil then FFlowSource := TDbFlowSource.Create(FCatalog   );
  if FFlowBuilder = nil then FFlowBuilder:= TFlowBuilder .Create(FFlowSource);
  if FFlowVM      = nil then
  begin
    FFlowVM:= TFlowViewModel.Create(FFlowBuilder);
    FFlowControl.Attach(FFlowVM);
  end;
  FFlowVM.SetRoot(ASymbolId);

  FFlowControl.Visible:= True;
  FFlowControl.BringToFront;
  FGraph       .Visible:= False;
  FEnterFlowBtn.Visible:= False;
  FFlowBtn     .Visible:= True;
  FModeBtn     .Visible:= True;
  UpdateModeButton;
  FStatus.SimpleText:= 'Flow: ' + ASymbolId;
end; // procedure

procedure TfrmMain.FlowBtnClick(Sender: TObject);
begin
  FFlowControl.Visible:= False;
  FGraph      .Visible:= True;
  FGraph.BringToFront;
  FEnterFlowBtn.Visible   := True;
  FFlowBtn     .Visible   := False;
  FModeBtn     .Visible   := False;
  FStatus      .SimpleText:= '';
end;

procedure TfrmMain.ModeBtnClick(Sender: TObject);
begin
  if FFlowVM <> nil then
  begin
    FFlowVM.ToggleGlobalMode;
    UpdateModeButton;
  end;
end;

procedure TfrmMain.UpdateModeButton;
begin
  if (FFlowVM <> nil) and (FFlowVM.Mode = fmExpanded) then FModeBtn.Caption:= 'Expanded'
  else FModeBtn.Caption:= 'Brief';
end;

procedure TfrmMain.FlowSelected(Sender: TObject; const ASymbolId: string);
begin
  SelectTreeNodeById(ASymbolId);
end;

procedure TfrmMain.GraphViewChanged(Sender: TObject);
begin
  UpdateShowAllButton;
  UpdateBreadcrumbs;
  UpdateNavButtons;   { Back/Forward enabled-state tracks the VM history }
end;

procedure TfrmMain.CrumbClick(Sender: TObject);
begin
  if FVM = nil then Exit;
  FVM.DrillToDepth((Sender as TButton).Tag);
  FGraph.FitToWindow; { zoom to the level we jumped back to }
end;

procedure TfrmMain.UpdateBreadcrumbs;
var
  Path: TArray<string>;
  I   : Integer       ;
  X   : Integer       ;
  P   : Integer       ;
  Btn : TButton       ;
  Sep : TLabel        ;
  Cap : string        ;
  S   : string        ;
begin
  if (FVM = nil) or (FCrumbBar = nil) then Exit;
  while FCrumbBar.ControlCount > 0 do FCrumbBar.Controls[0].Free;

  Path:= FVM.DrillPath;
  X:= 6;
  for I:= 0 to Length(Path) do
  begin
    if I > 0 then
    begin
      Sep:= TLabel.Create(FCrumbBar);
      Sep.Parent := FCrumbBar;
      Sep.Caption:= '>';
      Sep.Font.Color:= clSilver;
      Sep.Transparent:= True;
      Sep.Left       := X;
      Sep.Top        := 6;
      X:= X + Sep.Width + 4;
    end;

    if I = 0 then Cap:= 'Project'
    else
    begin
      S:= Path[I - 1];
      P:= LastDelimiter('.', S);
      if P > 0 then Cap:= Copy(S, P + 1, MaxInt) else Cap:= S;
      if Cap = '' then Cap:= S;
    end;

    Btn:= TButton.Create(FCrumbBar);
    Btn.Parent := FCrumbBar;
    Btn.Caption:= Cap;
    Btn.Tag    := I; { drill depth }
    Btn.Top    := 2;
    Btn.Height := 22;
    Btn.Left   := X;
    Btn.Width:= Length(Cap) * 7 + 24; { estimate; Panel.Canvas is protected }
    Btn.OnClick:= CrumbClick;
    { the last crumb is where we are now -> not clickable }
    Btn.Enabled:= I < Length(Path);
    X:= X + Btn.Width + 2;
  end; // for
end; // procedure

procedure TfrmMain.UpdateShowAllButton;
var
  N: Integer;
begin
  if FVM = nil then
  begin
    FShowAllBtn.Visible:= False;
    Exit;
  end;
  N:= FVM.HiddenTopLevelCount;
  if (not FVM.ShowAllTopLevel) and (N > 0) then
  begin
    FShowAllBtn.Caption:= Format('Show all units (%d hidden)', [N]);
    FShowAllBtn.Visible:= True;
  end
  else if FVM.ShowAllTopLevel then
  begin
    FShowAllBtn.Caption:= 'Show top ' + IntToStr(FVM.TopLevelLimit) + ' units';
    FShowAllBtn.Visible:= True;
  end
  else FShowAllBtn.Visible:= False;
end; // procedure

procedure TfrmMain.ShowAllBtnClick(Sender: TObject);
begin
  if FVM = nil then Exit;
  { Toggle: VM fires OnChanged -> control repaints + fires OnViewChanged
    -> UpdateShowAllButton refreshes caption/visibility. }
  FVM.SetShowAllTopLevel(not FVM.ShowAllTopLevel);
end;

procedure TfrmMain.GraphNodeClick(Sender: TObject; const A: TGraphNodeEventArgs);
var
  Doc : TGraphDoc;
  Info: string   ;
begin
  { Fires for every node click (the control's primary action -- expand or
    open-source -- runs after this and may overwrite the status text). }
  if A.Node = nil then Exit;
  FSelectedGraphId:= A.Node.Id; { remembered for the toolbar "Flow" button }
  Info:= 'Selected: ' + A.Node.Id;
  if A.Node.FilePath <> '' then Info:= Info + Format('  (%s:%d)', [ExtractFileName(A.Node.FilePath), A.Node.Line]);
  Doc:= FVM.SelectedDoc;
  if Doc.HasDoc and (Doc.Summary <> '') then Info:= Info + '  -- ' + Doc.Summary;
  FStatus.SimpleText:= Info;
end;

procedure TfrmMain.GraphSelectionChanged(Sender: TObject);
var
  Idx : Integer   ;
  N   : PGraphNode;
  Kind: string    ;
  Info: string    ;
begin
  if FVM = nil then Exit;
  Idx:= FVM.SelectedNodeIndex;
  if Idx < 0 then
  begin
    FSelectedGraphId:= ''; { selection cleared -> "Flow" has no target }
    Exit;
  end;
  N:= FVM.Data.NodeAt(Idx);
  FSelectedGraphId:= N.Id;
  case N.Kind of
    nkUnit     : Kind:= 'Unit';
    nkClass    : Kind:= 'Class';
    nkInterface: Kind:= 'Interface';
    nkRecord   : Kind:= 'Record';
    nkType     : Kind:= 'Type';
    nkMethod   : Kind:= 'Method';
    nkProcedure: Kind:= 'Procedure';
    nkFunction : Kind:= 'Function';
    nkProperty : Kind:= 'Property';
    nkField    : Kind:= 'Field';
    nkConst    : Kind:= 'Const';
    nkVar      : Kind:= 'Var';
    nkProject  : Kind:= 'Project';
    nkDfmForm  : Kind:= 'Form';
    else Kind:= 'Symbol';
  end; // case
  if (N.KindText <> '') and (N.Kind in [nkType, nkOther]) then Kind:= N.KindText; { precise indexed kind, e.g. enum / set / alias }
  Info:= Kind + ': ' + N.Id;
  if N.FilePath <> '' then Info:= Info + Format('  (%s:%d:%d)', [ExtractFileName(N.FilePath), N.Line, N.Col]);
  FStatus.SimpleText:= Info;

  { Graph -> tree: highlight the matching tree node if it is materialised
    (best-effort; the tree is lazy so collapsed branches are not searched). }
  SelectTreeNodeById(N.Id);
end; // procedure

procedure TfrmMain.SelectTreeNodeById(const AId: string);
var
  I  : Integer   ;
  Tag: TStructTag;
begin
  if FSyncingTree or (FTree = nil) or (AId = '') then Exit;
  for I:= 0 to FTree.Items.Count - 1 do
  begin
    Tag:= TStructTag(FTree.Items[I].Data);
    if (Tag <> nil) and (Tag.GraphId = AId) and (Tag.Kind in [skUnit, skSymbol]) then
    begin
      FSyncingTree:= True;
      try
        FTree.Items[I].MakeVisible;
        FTree.Selected:= FTree.Items[I];
      finally
        FSyncingTree:= False;
      end;
      Exit;
    end;
  end;
end; // procedure

procedure TfrmMain.GraphOpenSource(Sender: TObject; ANode: PGraphNode);
var
  F: string ;
  L: Integer;
  c: Integer;
begin
  if (FVM = nil) or (ANode = nil) then Exit;

  { The clicked node already carries its exact location (file/line/col,
    contract Q1-Q3) -- no qualified-name re-lookup, so overloaded methods
    resolve to the precise row the user clicked.  Fall back to LocateSymbol by
    id only if the node has no path (e.g. a synthetic node). }
  F:= ANode.FilePath;
  L:= ANode.Line;
  c:= ANode.Col;

  { DFM nodes: open the paired source unit, not the form designer (Q5). }
  if SameText(ExtractFileExt(F), '.dfm') then
  begin
    var PasF:= ChangeFileExt(F, '.pas');
    if FileExists(PasF) then
    begin
      F:= PasF;
      L:= 1; { line in the .dfm does not map to the .pas }
      c:= 1;
    end;
  end;

  if F = '' then
  begin
    FStatus.SimpleText:= 'No source location for: ' + ANode.Label_;
    Exit;
  end;

  { Prefer the running Delphi IDE via the drag-lint plugin's named pipe
    (caret-precise jump).  If no plugin is listening (standalone use), fall
    back to the OS file association so the file still opens. }
  if SendOpenSourceAt(F, L, c) then FStatus.SimpleText:= Format('Opened in IDE: %s:%d:%d', [F, L, c])
  else
  begin
    ShellExecute(0, 'open', PChar(F), nil, nil, SW_SHOWNORMAL);
    FStatus.SimpleText:= Format('Opened: %s  (line %d -- no IDE plugin listening)', [F, L]);
  end;
end; // procedure

procedure TfrmMain.GraphCrossDbJump(Sender: TObject; const AName: string);
begin
  if FVM = nil then Exit;
  FVM.JumpToCrossDb(AName);
  FStatus.SimpleText:= 'Jumped to: ' + AName;
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
  ZOOM_POS_MAX     = 1000;

function TfrmMain.PosToZoom(APos: Integer): Double;
var
  T: Double;
begin
  if APos <= 0 then begin Result:= ZOOM_MIN; Exit; end;
  if APos >= ZOOM_POS_MAX then begin Result:= ZOOM_MAX; Exit; end;
  T:= APos / ZOOM_POS_MAX;
  Result:= Exp(Ln(ZOOM_MIN) + T * (Ln(ZOOM_MAX) - Ln(ZOOM_MIN)));
end;

function TfrmMain.ZoomToPos(AZoom: Double): Integer;
var
  T: Double;
begin
  if AZoom <= ZOOM_MIN then begin Result:= 0; Exit; end;
  if AZoom >= ZOOM_MAX then begin Result:= ZOOM_POS_MAX; Exit; end;
  T:= (Ln(AZoom) - Ln(ZOOM_MIN)) / (Ln(ZOOM_MAX) - Ln(ZOOM_MIN));
  Result:= Round(T * ZOOM_POS_MAX);
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
  FSyncingZoom:= True;
  try
    FZoomBar.Position:= ZoomToPos(FGraph.ZoomLevel);
  finally
    FSyncingZoom:= False;
  end;
end;

end.
