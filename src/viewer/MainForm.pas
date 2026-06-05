unit MainForm;

{ Thin host form: builds IDbCatalog from --db args, wires IGraphViewModel
  and TDragLintGraphControl, shows selection/doc summary in the status bar.
  No business logic here -- all decisions live in the VM. }

interface

uses
  System.SysUtils, System.Classes, System.Math, System.UITypes, System.StrUtils,
  System.Generics.Collections, System.Generics.Defaults,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Vcl.Graphics, Vcl.Menus,
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI,
  DragLint.Graph.Types,
  DragLint.Graph.Source,
  DragLint.Graph.Source.Db,
  DragLint.Graph.ViewModel,
  DragLint.Graph.Control,
  DragLint.Graph.Style,
  DragLint.Graph.UsesQuery,
  DragLint.Graph.OpenSourceClient;

const
  WM_LOADGRAPH = WM_USER + 100;

type
  { Structure-tree node descriptor (attached to each TTreeNode.Data).  The tree
    is lazy: each node knows just enough to populate its children on expand. }
  TStructKind = (skUnit, skSection, skCategory, skSymbol,
                 skUsesIntf, skUsesImpl, skUsedBy);
  TStructTag = class
    Kind:      TStructKind;
    GraphId:   string;    { unit id (skUnit/skSection/skCategory) or symbol id (skSymbol) }
    Section:   string;    { 'interface' / 'implementation' (skSection, skCategory) }
    Cat:       Integer;   { category code (skCategory) }
    IsType:    Boolean;   { skSymbol that has members -> expandable }
    Populated: Boolean;
  end;

  TfrmMain = class(TForm)
  private
    FGraph:      TDragLintGraphControl;
    FStatus:     TStatusBar;
    FShowAllBtn: TButton;
    FZoomBar:    TTrackBar;
    FFitBtn:     TButton;
    FCrumbBar:   TPanel;
    FSyncingZoom: Boolean;
    FVM:         IGraphViewModel;
    FCatalog:    IDbCatalog;
    FDbPaths:    TArray<string>;
    FLoaded:     Boolean;
    { Structure panel (left dock) }
    FStructPanel: TPanel;
    FStructHdr:   TPanel;
    FSearchEdit:  TEdit;
    FPartialChk:  TCheckBox;
    FSplitter:    TSplitter;
    FTree:        TTreeView;
    FStructTags:  TObjectList<TStructTag>;
    FSyncingTree: Boolean;
    { Tree right-click menu (mirrors the graph's context actions) }
    FTreePopup:   TPopupMenu;
    FMiTOpen:     TMenuItem;
    FMiTGoto:     TMenuItem;
    FMiTWhere:    TMenuItem;
    FMiTCenter:   TMenuItem;
    FTreeCtxId:   string;     { symbol id of the right-clicked tree node }
    procedure CreateControls;
    procedure BuildStructureRoots;
    procedure ClearStructure;
    function  NewTag(AKind: TStructKind; const AGraphId, ASection: string;
      ACat: Integer): TStructTag;
    procedure TreeExpanding(Sender: TObject; Node: TTreeNode;
      var AllowExpansion: Boolean);
    procedure TreeChange(Sender: TObject; Node: TTreeNode);
    procedure SelectTreeNodeById(const AId: string);
    function  CategoryOf(AKind: TGraphNodeKind): Integer;
    { Search }
    procedure SearchChanged(Sender: TObject);
    procedure DoSearch;
    procedure BuildSearchResults(const ATerm: string; APartial: Boolean);
    function  UnitNameOf(ANodeIdx: Integer): string;
    { Tree context menu }
    procedure TreeContextPopup(Sender: TObject; MousePos: TPoint;
      var Handled: Boolean);
    procedure TreeCtxOpen(Sender: TObject);
    procedure TreeCtxGotoIntf(Sender: TObject);
    procedure TreeCtxWhereUsed(Sender: TObject);
    procedure TreeCtxCenter(Sender: TObject);
    procedure ParseDbArgs;
    procedure RunLoad;
    procedure FormShow(Sender: TObject);
    procedure WMLoadGraph(var Msg: TMessage); message WM_LOADGRAPH;
    procedure GraphNodeClick(Sender: TObject; const A: TGraphNodeEventArgs);
    procedure GraphSelectionChanged(Sender: TObject);
    procedure GraphOpenSource(Sender: TObject; ANode: PGraphNode);
    procedure GraphCrossDbJump(Sender: TObject; const AName: string);
    procedure GraphViewChanged(Sender: TObject);
    procedure ShowAllBtnClick(Sender: TObject);
    procedure UpdateShowAllButton;
    procedure UpdateBreadcrumbs;
    procedure CrumbClick(Sender: TObject);
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
    destructor Destroy; override;
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
  FStructTags := TObjectList<TStructTag>.Create(True);
  CreateControls;
  ParseDbArgs;
  OnShow := FormShow;
end;

destructor TfrmMain.Destroy;
begin
  FStructTags.Free;
  inherited;
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

  { Breadcrumb bar across the top -- created first so it sits below the
    top-right Fit/zoom/show-all controls in z-order. }
  FCrumbBar := TPanel.Create(Self);
  FCrumbBar.Parent     := Self;
  FCrumbBar.Align      := alTop;
  FCrumbBar.Height     := 26;
  FCrumbBar.BevelOuter := bvNone;
  FCrumbBar.Color      := TColor($00383838);
  FCrumbBar.ParentBackground := False;

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

  { Structure panel docked on the left: a header + a lazy tree of every unit's
    interface/implementation members.  Selecting an item shows it in the graph.
    Created before the graph so it claims the left edge; the graph takes the
    remaining client area. }
  FStructPanel := TPanel.Create(Self);
  FStructPanel.Parent     := Self;
  FStructPanel.Align      := alLeft;
  FStructPanel.Width      := 290;
  FStructPanel.BevelOuter := bvNone;
  FStructPanel.Color      := TColor($002A2A2A);
  FStructPanel.ParentBackground := False;

  FStructHdr := TPanel.Create(Self);
  FStructHdr.Parent     := FStructPanel;
  FStructHdr.Align      := alTop;
  FStructHdr.Height     := 22;
  FStructHdr.BevelOuter := bvNone;
  FStructHdr.Color      := TColor($00383838);
  FStructHdr.ParentBackground := False;
  FStructHdr.Font.Color := clWhite;
  FStructHdr.Font.Style := [fsBold];
  FStructHdr.Alignment  := taLeftJustify;
  FStructHdr.Caption    := '  Structure';

  { Search box (filters the tree to matching symbols). }
  FSearchEdit := TEdit.Create(Self);
  FSearchEdit.Parent    := FStructPanel;
  FSearchEdit.Align     := alTop;
  FSearchEdit.TextHint  := 'Search  (ABC, MSCTYPES.Plan, TPlanType.)';
  FSearchEdit.OnChange  := SearchChanged;

  FPartialChk := TCheckBox.Create(Self);
  FPartialChk.Parent     := FStructPanel;
  FPartialChk.Align      := alTop;
  FPartialChk.Height     := 20;
  FPartialChk.Caption    := 'Partial match (substring)';
  FPartialChk.Checked    := True;
  FPartialChk.Font.Color := clWhite;
  FPartialChk.OnClick    := SearchChanged;

  { Right-click menu mirroring the graph's context actions. }
  FTreePopup := TPopupMenu.Create(Self);
  FMiTOpen := TMenuItem.Create(FTreePopup);
  FMiTOpen.Caption := 'Open Source';
  FMiTOpen.OnClick := TreeCtxOpen;
  FTreePopup.Items.Add(FMiTOpen);
  FMiTGoto := TMenuItem.Create(FTreePopup);
  FMiTGoto.Caption := 'Go to Interface';
  FMiTGoto.OnClick := TreeCtxGotoIntf;
  FTreePopup.Items.Add(FMiTGoto);
  FMiTWhere := TMenuItem.Create(FTreePopup);
  FMiTWhere.Caption := 'Where Used (focus)';
  FMiTWhere.OnClick := TreeCtxWhereUsed;
  FTreePopup.Items.Add(FMiTWhere);
  FMiTCenter := TMenuItem.Create(FTreePopup);
  FMiTCenter.Caption := 'Show in Graph (center)';
  FMiTCenter.OnClick := TreeCtxCenter;
  FTreePopup.Items.Add(FMiTCenter);

  FTree := TTreeView.Create(Self);
  FTree.Parent        := FStructPanel;
  FTree.Align         := alClient;
  FTree.ReadOnly      := True;
  FTree.HideSelection := False;
  FTree.RowSelect     := True;
  FTree.ShowLines     := True;
  FTree.Color         := TColor($002A2A2A);
  FTree.Font.Color    := clWhite;
  FTree.Font.Name     := 'Segoe UI';
  FTree.Font.Size     := 9;
  FTree.OnExpanding   := TreeExpanding;
  FTree.OnChange      := TreeChange;
  FTree.PopupMenu     := FTreePopup;
  FTree.OnContextPopup := TreeContextPopup;

  FSplitter := TSplitter.Create(Self);
  FSplitter.Parent      := Self;
  FSplitter.Align       := alLeft;        { sits at the panel's right edge }
  FSplitter.Width       := 6;
  FSplitter.Beveled     := True;          { visible grab strip }
  FSplitter.Color       := TColor($00606060);
  FSplitter.ParentColor := False;
  FSplitter.MinSize     := 160;
  FSplitter.ResizeStyle := rsUpdate;      { live drag }

  FGraph := TDragLintGraphControl.Create(Self);
  FGraph.Parent := Self;
  FGraph.Align := alClient;
  FGraph.OnNodeClick       := GraphNodeClick;
  FGraph.OnSelectionChange := GraphSelectionChanged;
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
    FStatus.SimpleText := Format(
      'Loaded %s: %d nodes  |  Click a unit/class to expand  -  ' +
      'click a method to open source  -  Shift+click to focus  -  ' +
      'double-click to drill in  -  Backspace = back',
      [ExtractFileName(FDbPaths[0]), FVM.Data.NodeCount]);

  { Force a projection pass so FHiddenTopLevelCount is current before
    UpdateShowAllButton reads it -- Bind only schedules a paint. }
  FVM.Projection;
  UpdateShowAllButton;
  UpdateBreadcrumbs;
  BuildStructureRoots;
end;

{ ---- structure panel ----------------------------------------------------- }

function TfrmMain.CategoryOf(AKind: TGraphNodeKind): Integer;
begin
  case AKind of
    nkClass, nkInterface, nkRecord, nkType: Result := 0;   { Types }
    nkConst:                                 Result := 1;   { Consts }
    nkVar:                                   Result := 2;   { Vars }
    nkProcedure, nkFunction:                 Result := 3;   { Routines }
  else
    Result := 4;                                            { Other }
  end;
end;

function TfrmMain.NewTag(AKind: TStructKind; const AGraphId, ASection: string;
  ACat: Integer): TStructTag;
begin
  Result := TStructTag.Create;
  Result.Kind    := AKind;
  Result.GraphId := AGraphId;
  Result.Section := ASection;
  Result.Cat     := ACat;
  FStructTags.Add(Result);
end;

procedure TfrmMain.ClearStructure;
begin
  FTree.Items.Clear;       { frees TTreeNodes; their .Data tags are owned by
                             FStructTags and survive -- cleared next line }
  FStructTags.Clear;
end;

procedure TfrmMain.BuildStructureRoots;
var
  I: Integer;
  Units: TList<Integer>;
  N: PGraphNode;
  TN, Dummy: TTreeNode;
begin
  if (FVM = nil) or (FVM.Data = nil) then Exit;
  ClearStructure;
  FTree.Items.BeginUpdate;
  try
    Units := TList<Integer>.Create;
    try
      for I := 0 to FVM.Data.NodeCount - 1 do
        if FVM.Data.NodeAt(I).Kind = nkUnit then
          Units.Add(I);
      { alphabetical by unit name }
      Units.Sort(TComparer<Integer>.Construct(
        function(const A, B: Integer): Integer
        begin
          Result := CompareText(FVM.Data.NodeAt(A).Label_,
                                FVM.Data.NodeAt(B).Label_);
        end));

      for I in Units do
      begin
        N := FVM.Data.NodeAt(I);
        TN := FTree.Items.AddChild(nil, N.Label_);
        TN.Data := NewTag(skUnit, N.Id, '', 0);
        Dummy := FTree.Items.AddChild(TN, '');   { lazy: expand to populate }
        Dummy.Data := nil;
      end;
    finally
      Units.Free;
    end;
  finally
    FTree.Items.EndUpdate;
  end;
  FStructHdr.Caption := Format('  Structure  (%d units)', [FTree.Items.Count]);
end;

procedure TfrmMain.TreeExpanding(Sender: TObject; Node: TTreeNode;
  var AllowExpansion: Boolean);
const
  CAT_NAMES: array[0..4] of string =
    ('Types', 'Consts', 'Vars', 'Routines', 'Other');
var
  Tag, ChildTag: TStructTag;
  UnitIdx, SymIdx, Ci, c, Ui: Integer;
  Kids: TArray<Integer>;
  M: PGraphNode;
  Sect, Cap, Glyph: string;
  HasIntf, HasImpl: Boolean;
  CatCount: array[0..4] of Integer;
  Order: TList<Integer>;
  TN, Dummy: TTreeNode;
  UIntf, UImpl, UseArr: TArray<TUnitUseRow>;
  UBy: TArray<string>;

  function SectOf(AIdx: Integer): string;
  begin
    Result := FVM.Data.NodeAt(AIdx).Section;
    if Result = '' then Result := 'interface';
  end;

  function IsSectionMarker(AIdx: Integer): Boolean;
  var KT: string;
  begin
    KT := FVM.Data.NodeAt(AIdx).KindText;
    Result := (KT = 'initialization') or (KT = 'finalization');
  end;

  function AddNode(const ACaption: string; ATag: TStructTag;
    AExpandable: Boolean): TTreeNode;
  begin
    Result := FTree.Items.AddChild(Node, ACaption);
    Result.Data := ATag;
    if AExpandable then
    begin
      Dummy := FTree.Items.AddChild(Result, '');
      Dummy.Data := nil;
    end;
  end;

begin
  AllowExpansion := True;
  Tag := TStructTag(Node.Data);
  if (Tag = nil) or Tag.Populated then Exit;
  if FVM = nil then Exit;

  { drop the lazy dummy child(ren) }
  while Node.Count > 0 do Node.Item[0].Delete;
  Tag.Populated := True;

  case Tag.Kind of
    skUnit:
      begin
        UnitIdx := FVM.Data.FindNodeIndex(Tag.GraphId);
        if UnitIdx < 0 then Exit;
        Kids := FVM.Data.ChildrenOf(UnitIdx);
        HasIntf := False; HasImpl := False;
        for Ci in Kids do
        begin
          if IsSectionMarker(Ci) then Continue;   { init/final shown separately }
          if SectOf(Ci) = 'implementation' then HasImpl := True
          else HasIntf := True;
        end;
        if HasIntf then
          AddNode('Interface', NewTag(skSection, Tag.GraphId, 'interface', 0), True);
        if HasImpl then
          AddNode('Implementation', NewTag(skSection, Tag.GraphId, 'implementation', 0), True);
        { initialization / finalization markers (v0.41 scanner) as their own
          unit-level leaves -- click to jump to the section in the graph. }
        for Ci in Kids do
        begin
          M := FVM.Data.NodeAt(Ci);
          if M.KindText = 'initialization' then
            AddNode('Initialization', NewTag(skSymbol, M.Id, '', 0), False)
          else if M.KindText = 'finalization' then
            AddNode('Finalization', NewTag(skSymbol, M.Id, '', 0), False);
        end;
        { Uses-in / Used-by from the unit_uses table (exact, queried on demand). }
        if Length(FDbPaths) > 0 then
        begin
          if QueryUnitUses(FDbPaths[0], Tag.GraphId, UIntf, UImpl, UBy) then
          begin
            if Length(UIntf) > 0 then
              AddNode(Format('Uses - interface (%d)', [Length(UIntf)]),
                NewTag(skUsesIntf, Tag.GraphId, '', 0), True);
            if Length(UImpl) > 0 then
              AddNode(Format('Uses - implementation (%d)', [Length(UImpl)]),
                NewTag(skUsesImpl, Tag.GraphId, '', 0), True);
            if Length(UBy) > 0 then
              AddNode(Format('Used by (%d)', [Length(UBy)]),
                NewTag(skUsedBy, Tag.GraphId, '', 0), True);
          end;
        end;
      end;

    skUsesIntf, skUsesImpl:
      begin
        if Length(FDbPaths) = 0 then Exit;
        if not QueryUnitUses(FDbPaths[0], Tag.GraphId, UIntf, UImpl, UBy) then Exit;
        if Tag.Kind = skUsesImpl then UseArr := UImpl else UseArr := UIntf;
        for Ui := 0 to High(UseArr) do
        begin
          Cap := UseArr[Ui].UnitName;
          if UseArr[Ui].External then Cap := Cap + '   (external)';
          { leaf: skUnit tag -> clicking centers that unit in the graph if it
            is in the loaded store (external/library units just no-op). }
          AddNode(Cap, NewTag(skUnit, UseArr[Ui].UnitName, '', 0), False);
        end;
      end;

    skUsedBy:
      begin
        if Length(FDbPaths) = 0 then Exit;
        if not QueryUnitUses(FDbPaths[0], Tag.GraphId, UIntf, UImpl, UBy) then Exit;
        for Ui := 0 to High(UBy) do
          AddNode(UBy[Ui], NewTag(skUnit, UBy[Ui], '', 0), False);
      end;

    skSection:
      begin
        UnitIdx := FVM.Data.FindNodeIndex(Tag.GraphId);
        if UnitIdx < 0 then Exit;
        Kids := FVM.Data.ChildrenOf(UnitIdx);
        FillChar(CatCount, SizeOf(CatCount), 0);
        for Ci in Kids do
          if (SectOf(Ci) = Tag.Section) and not IsSectionMarker(Ci) then
            Inc(CatCount[CategoryOf(FVM.Data.NodeAt(Ci).Kind)]);
        for c := 0 to 4 do
          if CatCount[c] > 0 then
            AddNode(Format('%s (%d)', [CAT_NAMES[c], CatCount[c]]),
              NewTag(skCategory, Tag.GraphId, Tag.Section, c), True);
      end;

    skCategory:
      begin
        UnitIdx := FVM.Data.FindNodeIndex(Tag.GraphId);
        if UnitIdx < 0 then Exit;
        Kids := FVM.Data.ChildrenOf(UnitIdx);
        Order := TList<Integer>.Create;
        try
          for Ci in Kids do
            if (SectOf(Ci) = Tag.Section) and not IsSectionMarker(Ci) and
               (CategoryOf(FVM.Data.NodeAt(Ci).Kind) = Tag.Cat) then
              Order.Add(Ci);
          Order.Sort(TComparer<Integer>.Construct(
            function(const A, B: Integer): Integer
            begin
              Result := CompareText(FVM.Data.NodeAt(A).Label_,
                                    FVM.Data.NodeAt(B).Label_);
            end));
          for Ci in Order do
          begin
            M := FVM.Data.NodeAt(Ci);
            Cap := M.Label_;
            if (M.Kind = nkType) and (M.KindText <> '') then
              Cap := Cap + '  : ' + M.KindText;
            ChildTag := NewTag(skSymbol, M.Id, '', 0);
            ChildTag.IsType := Length(FVM.Data.ChildrenOf(Ci)) > 0;
            AddNode(Cap, ChildTag, ChildTag.IsType);
          end;
        finally
          Order.Free;
        end;
      end;

    skSymbol:
      begin
        SymIdx := FVM.Data.FindNodeIndex(Tag.GraphId);
        if SymIdx < 0 then Exit;
        Kids := FVM.Data.ChildrenOf(SymIdx);
        Order := TList<Integer>.Create;
        try
          for Ci in Kids do Order.Add(Ci);
          Order.Sort(TComparer<Integer>.Construct(
            function(const A, B: Integer): Integer
            var KA, KB: Integer;
            begin
              KA := Ord(FVM.Data.NodeAt(A).Kind);
              KB := Ord(FVM.Data.NodeAt(B).Kind);
              if KA <> KB then Exit(KA - KB);
              Result := CompareText(FVM.Data.NodeAt(A).Label_,
                                    FVM.Data.NodeAt(B).Label_);
            end));
          for Ci in Order do
          begin
            M := FVM.Data.NodeAt(Ci);
            Glyph := VisibilityGlyph(M.Modifiers);
            if Glyph <> '' then Glyph := Glyph + ' ';
            Cap := Glyph + M.Label_;
            if M.Signature <> '' then Cap := Cap + ': ' + M.Signature;
            ChildTag := NewTag(skSymbol, M.Id, '', 0);
            ChildTag.IsType := Length(FVM.Data.ChildrenOf(Ci)) > 0;
            TN := AddNode(Cap, ChildTag, ChildTag.IsType);
            if TN = nil then ;
          end;
        finally
          Order.Free;
        end;
      end;
  end;
end;

procedure TfrmMain.TreeChange(Sender: TObject; Node: TTreeNode);
var
  Tag: TStructTag;
begin
  if FSyncingTree or (Node = nil) or (FGraph = nil) then Exit;
  Tag := TStructTag(Node.Data);
  if (Tag = nil) or (Tag.GraphId = '') then Exit;
  if not (Tag.Kind in [skUnit, skSymbol]) then Exit;
  { Show the selected item in the graph (reveal + center). }
  FSyncingTree := True;
  try
    FGraph.CenterOnNode(Tag.GraphId);
  finally
    FSyncingTree := False;
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
  Term := Trim(FSearchEdit.Text);
  if Term = '' then
    BuildStructureRoots
  else
    BuildSearchResults(Term, FPartialChk.Checked);
end;

function TfrmMain.UnitNameOf(ANodeIdx: Integer): string;
var
  Idx, Guard: Integer;
  N: PGraphNode;
begin
  Result := '';
  Idx := ANodeIdx;
  Guard := 0;
  while (Idx >= 0) and (Guard < 64) do
  begin
    N := FVM.Data.NodeAt(Idx);
    if N.Kind = nkUnit then Exit(N.Label_);
    Idx := FVM.Data.ParentIndexOf(Idx);
    Inc(Guard);
  end;
end;

procedure TfrmMain.BuildSearchResults(const ATerm: string; APartial: Boolean);
const
  MAX_RESULTS = 1000;
var
  I, DotP: Integer;
  Scope, Leaf, Cap, KindS: string;
  N: PGraphNode;
  Matches: TList<Integer>;
  ScopeOk, LeafOk: Boolean;
  TN: TTreeNode;
  Capped: Boolean;
begin
  { "Unit.Type.leaf" -> scope = before last dot (matched against the qualified
    name), leaf = after (matched against the symbol's own name).  No dot ->
    match the name only.  Trailing dot -> everything in that scope. }
  DotP := LastDelimiter('.', ATerm);
  if DotP > 0 then
  begin
    Scope := Copy(ATerm, 1, DotP - 1);
    Leaf  := Copy(ATerm, DotP + 1, MaxInt);
  end
  else
  begin
    Scope := '';
    Leaf  := ATerm;
  end;

  ClearStructure;
  Matches := TList<Integer>.Create;
  Capped := False;
  try
    for I := 0 to FVM.Data.NodeCount - 1 do
    begin
      N := FVM.Data.NodeAt(I);
      if (N.Kind = nkProject) or (N.Id = '@project') then Continue;

      if Scope = '' then ScopeOk := True
      else ScopeOk := ContainsText(N.Id, Scope);
      if not ScopeOk then Continue;

      if Leaf = '' then LeafOk := True
      else if APartial then LeafOk := ContainsText(N.Label_, Leaf)
      else LeafOk := SameText(N.Label_, Leaf);
      if not LeafOk then Continue;

      Matches.Add(I);
      if Matches.Count >= MAX_RESULTS then begin Capped := True; Break; end;
    end;

    Matches.Sort(TComparer<Integer>.Construct(
      function(const A, B: Integer): Integer
      begin
        Result := CompareText(FVM.Data.NodeAt(A).Label_,
                              FVM.Data.NodeAt(B).Label_);
        if Result = 0 then
          Result := CompareText(FVM.Data.NodeAt(A).Id, FVM.Data.NodeAt(B).Id);
      end));

    FTree.Items.BeginUpdate;
    try
      for I in Matches do
      begin
        N := FVM.Data.NodeAt(I);
        KindS := N.KindText;
        if KindS = '' then KindS := '?';
        Cap := N.Label_ + '   : ' + KindS + '   (' + UnitNameOf(I) + ')';
        TN := FTree.Items.AddChild(nil, Cap);
        TN.Data := NewTag(skSymbol, N.Id, '', 0);
      end;
    finally
      FTree.Items.EndUpdate;
    end;

    if Capped then
      FStructHdr.Caption := Format('  Search: %d+ results (capped)', [Matches.Count])
    else
      FStructHdr.Caption := Format('  Search: %d result(s)', [Matches.Count]);
  finally
    Matches.Free;
  end;
end;

{ ---- tree context menu (mirrors the graph's right-click actions) ---- }

procedure TfrmMain.TreeContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
var
  Node: TTreeNode;
  Tag:  TStructTag;
  PN:   PGraphNode;
begin
  Handled := False;
  if (MousePos.X < 0) or (MousePos.Y < 0) then
    Node := FTree.Selected
  else
    Node := FTree.GetNodeAt(MousePos.X, MousePos.Y);
  if Node = nil then begin Handled := True; Exit; end;

  FTree.Selected := Node;     { also drives TreeChange -> graph selection }
  Tag := TStructTag(Node.Data);
  if (Tag = nil) or (Tag.GraphId = '') or
     not (Tag.Kind in [skUnit, skSymbol]) then
  begin
    Handled := True;          { group node -> no menu }
    Exit;
  end;

  FTreeCtxId := Tag.GraphId;
  PN := FVM.Data.FindNode(FTreeCtxId);
  FMiTOpen.Enabled := (PN <> nil) and (PN.FilePath <> '');
end;

procedure TfrmMain.TreeCtxOpen(Sender: TObject);
var
  PN: PGraphNode;
begin
  if FVM = nil then Exit;
  PN := FVM.Data.FindNode(FTreeCtxId);
  if PN <> nil then GraphOpenSource(Self, PN);
end;

procedure TfrmMain.TreeCtxGotoIntf(Sender: TObject);
begin
  if FGraph <> nil then FGraph.GoToInterfaceFor(FTreeCtxId);
end;

procedure TfrmMain.TreeCtxWhereUsed(Sender: TObject);
begin
  if FGraph <> nil then FGraph.WhereUsedFor(FTreeCtxId);
end;

procedure TfrmMain.TreeCtxCenter(Sender: TObject);
begin
  if FGraph <> nil then FGraph.CenterOnNode(FTreeCtxId);
end;

procedure TfrmMain.GraphViewChanged(Sender: TObject);
begin
  UpdateShowAllButton;
  UpdateBreadcrumbs;
end;

procedure TfrmMain.CrumbClick(Sender: TObject);
begin
  if FVM = nil then Exit;
  FVM.DrillToDepth((Sender as TButton).Tag);
  FGraph.FitToWindow;     { zoom to the level we jumped back to }
end;

procedure TfrmMain.UpdateBreadcrumbs;
var
  Path: TArray<string>;
  I, X, p: Integer;
  Btn: TButton;
  Sep: TLabel;
  Cap, S: string;
begin
  if (FVM = nil) or (FCrumbBar = nil) then Exit;
  while FCrumbBar.ControlCount > 0 do
    FCrumbBar.Controls[0].Free;

  Path := FVM.DrillPath;
  X := 6;
  for I := 0 to Length(Path) do
  begin
    if I > 0 then
    begin
      Sep := TLabel.Create(FCrumbBar);
      Sep.Parent := FCrumbBar;
      Sep.Caption := '>';
      Sep.Font.Color := clSilver;
      Sep.Transparent := True;
      Sep.Left := X;
      Sep.Top := 6;
      X := X + Sep.Width + 4;
    end;

    if I = 0 then
      Cap := 'Project'
    else
    begin
      S := Path[I - 1];
      p := LastDelimiter('.', S);
      if p > 0 then Cap := Copy(S, p + 1, MaxInt) else Cap := S;
      if Cap = '' then Cap := S;
    end;

    Btn := TButton.Create(FCrumbBar);
    Btn.Parent  := FCrumbBar;
    Btn.Caption := Cap;
    Btn.Tag     := I;                 { drill depth }
    Btn.Top     := 2;
    Btn.Height  := 22;
    Btn.Left    := X;
    Btn.Width   := Length(Cap) * 7 + 24;   { estimate; Panel.Canvas is protected }
    Btn.OnClick := CrumbClick;
    { the last crumb is where we are now -> not clickable }
    Btn.Enabled := I < Length(Path);
    X := X + Btn.Width + 2;
  end;
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
  { Fires for every node click (the control's primary action -- expand or
    open-source -- runs after this and may overwrite the status text). }
  if A.Node = nil then Exit;
  Info := 'Selected: ' + A.Node.Id;
  if A.Node.FilePath <> '' then
    Info := Info + Format('  (%s:%d)', [ExtractFileName(A.Node.FilePath), A.Node.Line]);
  Doc := FVM.SelectedDoc;
  if Doc.HasDoc and (Doc.Summary <> '') then
    Info := Info + '  -- ' + Doc.Summary;
  FStatus.SimpleText := Info;
end;

procedure TfrmMain.GraphSelectionChanged(Sender: TObject);
var
  Idx:  Integer;
  N:    PGraphNode;
  Kind: string;
  Info: string;
begin
  if FVM = nil then Exit;
  Idx := FVM.SelectedNodeIndex;
  if Idx < 0 then Exit;
  N := FVM.Data.NodeAt(Idx);
  case N.Kind of
    nkUnit:      Kind := 'Unit';
    nkClass:     Kind := 'Class';
    nkInterface: Kind := 'Interface';
    nkRecord:    Kind := 'Record';
    nkType:      Kind := 'Type';
    nkMethod:    Kind := 'Method';
    nkProcedure: Kind := 'Procedure';
    nkFunction:  Kind := 'Function';
    nkProperty:  Kind := 'Property';
    nkField:     Kind := 'Field';
    nkConst:     Kind := 'Const';
    nkVar:       Kind := 'Var';
    nkProject:   Kind := 'Project';
    nkDfmForm:   Kind := 'Form';
  else
    Kind := 'Symbol';
  end;
  if (N.KindText <> '') and (N.Kind in [nkType, nkOther]) then
    Kind := N.KindText;   { precise indexed kind, e.g. enum / set / alias }
  Info := Kind + ': ' + N.Id;
  if N.FilePath <> '' then
    Info := Info + Format('  (%s:%d:%d)', [ExtractFileName(N.FilePath), N.Line, N.Col]);
  FStatus.SimpleText := Info;

  { Graph -> tree: highlight the matching tree node if it is materialised
    (best-effort; the tree is lazy so collapsed branches are not searched). }
  SelectTreeNodeById(N.Id);
end;

procedure TfrmMain.SelectTreeNodeById(const AId: string);
var
  I: Integer;
  Tag: TStructTag;
begin
  if FSyncingTree or (FTree = nil) or (AId = '') then Exit;
  for I := 0 to FTree.Items.Count - 1 do
  begin
    Tag := TStructTag(FTree.Items[I].Data);
    if (Tag <> nil) and (Tag.GraphId = AId) and
       (Tag.Kind in [skUnit, skSymbol]) then
    begin
      FSyncingTree := True;
      try
        FTree.Items[I].MakeVisible;
        FTree.Selected := FTree.Items[I];
      finally
        FSyncingTree := False;
      end;
      Exit;
    end;
  end;
end;

procedure TfrmMain.GraphOpenSource(Sender: TObject; ANode: PGraphNode);
var
  F: string;
  L, C: Integer;
begin
  if (FVM = nil) or (ANode = nil) then Exit;

  { The clicked node already carries its exact location (file/line/col,
    contract Q1-Q3) -- no qualified-name re-lookup, so overloaded methods
    resolve to the precise row the user clicked.  Fall back to LocateSymbol by
    id only if the node has no path (e.g. a synthetic node). }
  F := ANode.FilePath;
  L := ANode.Line;
  C := ANode.Col;

  { DFM nodes: open the paired source unit, not the form designer (Q5). }
  if SameText(ExtractFileExt(F), '.dfm') then
  begin
    var PasF := ChangeFileExt(F, '.pas');
    if FileExists(PasF) then
    begin
      F := PasF;
      L := 1;          { line in the .dfm does not map to the .pas }
      C := 1;
    end;
  end;

  if F = '' then
  begin
    FStatus.SimpleText := 'No source location for: ' + ANode.Label_;
    Exit;
  end;

  { Prefer the running Delphi IDE via the drag-lint plugin's named pipe
    (caret-precise jump).  If no plugin is listening (standalone use), fall
    back to the OS file association so the file still opens. }
  if SendOpenSourceAt(F, L, C) then
    FStatus.SimpleText := Format('Opened in IDE: %s:%d:%d', [F, L, C])
  else
  begin
    ShellExecute(0, 'open', PChar(F), nil, nil, SW_SHOWNORMAL);
    FStatus.SimpleText :=
      Format('Opened: %s  (line %d -- no IDE plugin listening)', [F, L]);
  end;
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
