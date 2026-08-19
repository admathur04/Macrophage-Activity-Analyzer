function results = macrophage_phagocytosis_ui_puncta_final()
% macrophage_phagocytosis_ui_puncta_final
%
% Analyses macrophage phagocytic functionality using two channels:
%   - TRANS image:  all macrophages detected (brightfield / trans-illumination)
%   - AF555 image:  pHrodo-dextran fluorescence puncta inside TRANS cells
%
% OUTPUTS (in results struct):
%   results.count_total_cells     — total macrophages (TRANS channel)
%   results.count_phago_cells     — macrophages with puncta fraction above cutoff
%   results.fraction_phago        — phago cells / total cells  (0–1)
%   results.percent_phago         — fraction × 100
%   results.per_cell_puncta_fraction — puncta area / TRANS cell area
%   results.per_cell_puncta_count    — accepted punctum-sized candidates per cell
%
% PIPELINE:
%   TRANS  → same B&W binarization as rbc_wbc_ratio_ui_v6_bw (ring top-hat +
%             adaptive threshold + watershed) to detect ALL macrophages.
%   AF555  → PunctaFinder-lite object scoring inside each accepted TRANS mask:
%             find punctum-sized local maxima, compare each candidate disk to
%             its local surrounding ring and the whole-cell baseline, reject
%             duplicates, build a puncta area mask from accepted objects, then
%             classify the cell by puncta area fraction.
%
% Usage:
%   results = macrophage_phagocytosis_ui_puncta_final;

clc;
results           = struct();
results.version   = 'macrophage_phago_puncta_final';
results.timestamp = datestr(now,'yyyy-mm-dd HH:MM:SS');

% -----------------------------------------------------------------------
% Load images
% -----------------------------------------------------------------------
[transFile, transPath] = uigetfile({'*.tif;*.tiff;*.png;*.jpg;*.jpeg','Image files'}, ...
    'Select TRANS image (all macrophages)');
if isequal(transFile,0), results = []; return; end

[af555File, af555Path] = uigetfile({'*.tif;*.tiff;*.png;*.jpg;*.jpeg','Image files'}, ...
    'Select AF555 image (pHrodo fluorescence — active cells)');
if isequal(af555File,0), results = []; return; end

transFull = fullfile(transPath, transFile);
af555Full = fullfile(af555Path, af555File);

Itrans = readToGray(transFull, 'trans');
Iaf555 = readToGray(af555Full, 'fluor');

results.files.trans = transFull;
results.files.af555 = af555Full;

% -----------------------------------------------------------------------
% Default / loaded params
% -----------------------------------------------------------------------
paramsTrans = defaultParams('trans');
paramsAF555 = defaultParams('fluor');

choice = questdlg('Use previously saved parameters?','Parameters', ...
    'Load params .mat','Use defaults','Use defaults');
if strcmp(choice,'Load params .mat')
    [pFile, pPath] = uigetfile('*.mat','Select params MAT file');
    if ~isequal(pFile,0)
        tmp = load(fullfile(pPath,pFile));
        if isfield(tmp,'paramsOut')
            if isfield(tmp.paramsOut,'trans'),  paramsTrans = sanitizeParams(tmp.paramsOut.trans,'trans'); end
            if isfield(tmp.paramsOut,'af555'),  paramsAF555 = sanitizeParams(tmp.paramsOut.af555,'fluor'); end
        else
            warndlg('No paramsOut in file. Using defaults.','Params');
        end
    end
end

% -----------------------------------------------------------------------
% State
% -----------------------------------------------------------------------
Strans = initState(Itrans, 'TRANS',  paramsTrans);
Saf555 = initState(Iaf555, 'AF555',  paramsAF555);

% -----------------------------------------------------------------------
% Figure
% -----------------------------------------------------------------------
scr  = get(0,'ScreenSize');
figW = min(1360, scr(3)-80);  figW = max(figW, 1000);
figH = min(860,  scr(4)-100); figH = max(figH, 680);

hFig = figure('Name','Macrophage Phagocytosis UI (object-level puncta)', ...
    'Color',[0.96 0.96 0.96],'NumberTitle','off', ...
    'MenuBar','none','ToolBar','none', ...
    'Units','pixels','Position',centerFig(figW,figH), ...
    'CloseRequestFcn',@onCloseRequest);

% ---- Persistent pick-mode state ----
% pickMode: '' | 'real' | 'fake'
% No blocking loops — figure callbacks handle all clicks.
pickMode = '';   % current mode

% Tabs: TRANS | TRANS B&W | AF555 | Puncta Counts | Overlay
tg        = uitabgroup(hFig,'Units','normalized','Position',[0.01 0.01 0.72 0.98]);
tabTrans  = uitab(tg,'Title','TRANS (All Cells)');
tabBW     = uitab(tg,'Title','TRANS B&W Preview');
tabAF555  = uitab(tg,'Title','AF555 Puncta');
tabCounts = uitab(tg,'Title','Puncta Counts');
tabOver   = uitab(tg,'Title','Overlay / Results');

axTrans = axes('Parent',tabTrans,'Units','normalized','Position',[0.02 0.05 0.96 0.92]);
axBW    = axes('Parent',tabBW,   'Units','normalized','Position',[0.02 0.05 0.96 0.92]);
axAF555 = axes('Parent',tabAF555,'Units','normalized','Position',[0.02 0.05 0.96 0.92]);
axCounts = axes('Parent',tabCounts,'Units','normalized','Position',[0.02 0.05 0.96 0.92]);

% Overlay tab: left = image (60%), right = two plots stacked (40%)
axOver  = axes('Parent',tabOver,'Units','normalized','Position',[0.01 0.05 0.57 0.91]);
axHist  = axes('Parent',tabOver,'Units','normalized','Position',[0.62 0.55 0.36 0.38]);
axBar   = axes('Parent',tabOver,'Units','normalized','Position',[0.62 0.07 0.36 0.38]);

% Background ROI state: [x y w h] in image pixels, empty = none
bgRect = [];   % set by "Set background ROI" button

% Controls panel
pnl = uipanel('Parent',hFig,'Title','Controls','FontSize',11, ...
    'Units','normalized','Position',[0.74 0.01 0.25 0.98]);

% ---- Layout helpers (ultra-compact) ----
r    = 0.968;
dR   = @(h) h+0.002;
btnH = 0.036;
fsS  = 8;
fsM  = 9;
fsL  = 10;

txtActive = mkTxt(pnl,'ACTIVE: TRANS',r,0.024,10,true);

r = r - dR(0.024);
chkUseGuidance = uicontrol(pnl,'Style','checkbox', ...
    'String','Use guidance picks','Value',1, ...
    'Units','normalized','Position',[0.05 r 0.90 0.022],'FontSize',7, ...
    'Callback',@(~,~)syncStatus());

r = r - dR(0.022);
mkTxt(pnl,'Aggressiveness (fewer <- -> more)',r,0.016,7,false);
r = r - dR(0.016);
sldAgg = uicontrol(pnl,'Style','slider','Min',0,'Max',1,'Value',0.5, ...
    'Units','normalized','Position',[0.06 r 0.88 0.020], ...
    'Callback',@(~,~)onAggChanged());
r = r - dR(0.040);
mkBtn(pnl,'< LESS',[0.06 r 0.42 0.032],fsS,@onLess);
mkBtn(pnl,'MORE >',[0.52 r 0.42 0.032],fsS,@onMore);

r = r - dR(0.032);
mkTxt(pnl,'-- Step 1: Auto-detect --',r,0.016,7,false);
r = r - dR(0.016);
mkBtn(pnl,'>> Auto-detect',[0.06 r 0.88 0.044],fsL,@onAutoDetect,'bold');

r = r - dR(0.044);
mkTxt(pnl,'-- Step 2: Refine picks --',r,0.016,7,false);
r = r - dR(0.016);
btnPickReal = mkBtn(pnl,'+ REAL',[0.06 r 0.42 btnH],fsM,@onPickReal);
btnPickFake = mkBtn(pnl,'x FAKE',[0.52 r 0.42 btnH],fsM,@onPickFake);
r = r - dR(btnH);
mkBtn(pnl,'Undo pick',[0.06 r 0.42 btnH],fsS,@onUndoPick);
mkBtn(pnl,'Clr picks',[0.52 r 0.42 btnH],fsS,@onClearPicks);
r = r - dR(btnH);
mkBtn(pnl,'>> Update detection',[0.06 r 0.88 0.042],fsL,@onUpdateDetection,'bold');

r = r - dR(0.042);
mkTxt(pnl,'-- View / Edit --',r,0.016,7,false);
r = r - dR(0.016);
mkBtn(pnl,'Preview B&W',       [0.06 r 0.44 btnH],fsS,@onPreviewBW);
mkBtn(pnl,'Feature map',       [0.54 r 0.40 btnH],fsS,@onPreviewFeat);
r = r - dR(btnH);
mkBtn(pnl,'Deselect polygon',  [0.06 r 0.88 btnH],fsS,@onDeselect);
r = r - dR(btnH);
mkBtn(pnl,'Reset deselection', [0.06 r 0.88 btnH],fsS,@onResetDeselection);
r = r - dR(btnH);
mkBtn(pnl,'Set BG region',     [0.06 r 0.88 btnH],fsS,@onSetBgROI);
r = r - dR(btnH);
mkBtn(pnl,'Edit params',       [0.06 r 0.44 btnH],fsS,@onEditParams);
mkBtn(pnl,'Save params',       [0.54 r 0.40 btnH],fsS,@onSaveParamsNow);

% ---- Analyse: populate overlay tab (run Update detection first if needed) ----
r = r - dR(btnH);
hBtnAnalyse = mkBtn(pnl,'  Analyse / Show Results  ',[0.06 r 0.88 0.050],fsL+1,@onAnalyse,'bold');
set(hBtnAnalyse,'BackgroundColor',[0.18 0.44 0.80],'ForegroundColor',[1 1 1]);

r = r - dR(0.050);
txtMode = mkTxt(pnl,'Mode: idle',r,0.020,fsS+2,false);

r = r - dR(0.128);
txtCounts = uicontrol(pnl,'Style','text','String','', ...
    'Units','normalized','Position',[0.05 r 0.90 0.122], ...
    'FontSize',fsS+2,'HorizontalAlignment','left', ...
    'BackgroundColor',get(pnl,'BackgroundColor'));

mkBtn(pnl,'Save & Exit (Results)',[0.06 0.010 0.88 0.048],fsL,@onSaveAndExit,'bold');

tg.SelectionChangedFcn = @onTabChanged;

% Initial render
renderChannel(axTrans, Strans);
renderAF555Tab(axAF555, Strans, Saf555, Iaf555, bgRect);
renderPunctaCountTab(axCounts, Strans, Saf555, Iaf555, bgRect);
showBWPreview(axBW, Strans);
syncStatus();

% Install permanent non-blocking figure click/key handlers for pick mode
hFig.WindowButtonDownFcn = @onFigClick;
hFig.WindowKeyPressFcn   = @onFigKey;

uiwait(hFig);


% =======================================================================
%  CALLBACKS
% =======================================================================

    function onTabChanged(~,~)
        switch tg.SelectedTab
            case tabTrans,  txtActive.String = 'ACTIVE: TRANS';
            case tabBW,     txtActive.String = 'ACTIVE: TRANS (B&W)';
            case tabAF555,  txtActive.String = 'ACTIVE: AF555';
            case tabCounts
                txtActive.String = 'ACTIVE: Puncta Counts';
                try
                    renderPunctaCountTab(axCounts, Strans, Saf555, Iaf555, bgRect);
                catch
                end
            case tabOver
                txtActive.String = 'ACTIVE: Overlay';
                % Auto-refresh overlay plots whenever the user switches to this tab
                if ~isempty(Strans.detectMask) && any(Strans.detectMask)
                    try
                        renderOverlay(axOver, axHist, axBar, Strans, Saf555, Iaf555, bgRect);
                    catch
                    end
                end
        end
        syncStatus();
    end

    function S = getActiveState()
        if tg.SelectedTab == tabAF555
            S = Saf555;
        else
            S = Strans;
        end
    end

    function setActiveState(S)
        if strcmp(S.channelName,'AF555')
            Saf555 = S;
            renderAF555Tab(axAF555, Strans, Saf555, Iaf555, bgRect);
            renderPunctaCountTab(axCounts, Strans, Saf555, Iaf555, bgRect);
        else
            % Preserve picks that were stored directly in Strans by onPickReal/Fake.
            % If the incoming S has fewer picks than Strans, keep Strans picks.
            % This prevents setActiveState (called after LESS/MORE/aggressiveness
            % changes) from wiping out picks that were added post-auto-detect.
            if size(S.realPts,1) < size(Strans.realPts,1)
                S.realPts = Strans.realPts;
            end
            if size(S.fakePts,1) < size(Strans.fakePts,1)
                S.fakePts = Strans.fakePts;
            end
            if numel(S.pickHistory) < numel(Strans.pickHistory)
                S.pickHistory = Strans.pickHistory;
            end
            Strans = S;
            renderChannel(axTrans, Strans);
            showBWPreview(axBW, Strans);
            renderAF555Tab(axAF555, Strans, Saf555, Iaf555, bgRect);
            renderPunctaCountTab(axCounts, Strans, Saf555, Iaf555, bgRect);
        end
        syncStatus();
    end

    function ax = getActiveAxes()
        if tg.SelectedTab == tabAF555, ax = axAF555; else, ax = axTrans; end
    end

    function onAggChanged()
        S = getActiveState();
        S.params.aggressiveness = sldAgg.Value;
        S.params = applyAggressiveness(S.params);
        setActiveState(S);
    end

    function onMore(~,~)
        S = getActiveState();
        S.params.aggressiveness = min(1, S.params.aggressiveness+0.10);
        sldAgg.Value = S.params.aggressiveness;
        S.params = applyAggressiveness(S.params);
        setActiveState(S);
    end

    function onLess(~,~)
        S = getActiveState();
        S.params.aggressiveness = max(0, S.params.aggressiveness-0.10);
        sldAgg.Value = S.params.aggressiveness;
        S.params = applyAggressiveness(S.params);
        setActiveState(S);
    end

    function onPickReal(~,~)
        % Toggle REAL pick mode on/off — non-blocking.
        if strcmp(pickMode,'real')
            % Already in REAL mode — toggle off
            pickMode = '';
            txtMode.String = 'Mode: idle  (click >> Update detection to apply)';
            renderChannel(axTrans, Strans);
        else
            pickMode = 'real';
            tg.SelectedTab = tabTrans; drawnow;
            txtMode.String = 'REAL mode ON: left-click cells to add  |  click "+ REAL" again or Esc to finish';
        end
    end

    function onPickFake(~,~)
        % Toggle FAKE pick mode on/off — non-blocking.
        if strcmp(pickMode,'fake')
            pickMode = '';
            txtMode.String = 'Mode: idle  (click >> Update detection to apply)';
            renderChannel(axTrans, Strans);
        else
            pickMode = 'fake';
            tg.SelectedTab = tabTrans; drawnow;
            txtMode.String = 'FAKE mode ON: left-click false detections  |  click "x FAKE" again or Esc to finish';
        end
    end

    % ---- Permanent figure click handler ----
    function onFigClick(~,~)
        if isempty(pickMode), return; end
        % Only act on clicks inside axTrans
        cp = get(axTrans,'CurrentPoint');
        cx = cp(1,1); cy = cp(1,2);
        xl = get(axTrans,'XLim'); yl = get(axTrans,'YLim');
        if cx<xl(1)||cx>xl(2)||cy<yl(1)||cy>yl(2), return; end
        % Right-click ends mode
        selType = get(hFig,'SelectionType');
        if strcmp(selType,'alt')
            pickMode = '';
            txtMode.String = 'Mode: idle  (click >> Update detection to apply)';
            renderChannel(axTrans, Strans);
            return;
        end
        % Left-click: record point
        if strcmp(pickMode,'real')
            Strans.realPts(end+1,:) = [cx cy];
            Strans.pickHistory(end+1) = makePickHist('real',1);
            markerStyle = 'o'; markerColor = [0 0.85 0];
            n = size(Strans.realPts,1);
            labelStr = sprintf('R%d',n);
        else
            Strans.fakePts(end+1,:) = [cx cy];
            Strans.pickHistory(end+1) = makePickHist('fake',1);
            markerStyle = 'x'; markerColor = [1 0.2 0.2];
            n = size(Strans.fakePts,1);
            labelStr = sprintf('F%d',n);
        end
        % Draw marker on image immediately without full re-render
        hold(axTrans,'on');
        plot(axTrans, cx, cy, markerStyle, 'MarkerSize',16, ...
            'Color',markerColor, 'LineWidth',2.5);
        text(axTrans, cx+8, cy, labelStr, ...
            'Color',markerColor,'FontSize',8,'FontWeight','bold');
        hold(axTrans,'off');
        drawnow;
        syncStatus();
    end

    % ---- Permanent figure key handler ----
    function onFigKey(~,evt)
        if isempty(pickMode), return; end
        if isempty(evt), return; end
        if any(strcmp(evt.Key,{'escape','return','space'}))
            pickMode = '';
            txtMode.String = 'Mode: idle  (click >> Update detection to apply)';
            renderChannel(axTrans, Strans);
            syncStatus();
        end
    end

    function onUndoPick(~,~)
        % Undo last pick session — works on Strans directly
        if isempty(Strans.pickHistory), return; end
        last = Strans.pickHistory(end);
        Strans.pickHistory(end) = [];
        if strcmp(last.kind,'real')
            Strans.realPts = Strans.realPts(1:max(0,size(Strans.realPts,1)-last.n),:);
        else
            Strans.fakePts = Strans.fakePts(1:max(0,size(Strans.fakePts,1)-last.n),:);
        end
        txtMode.String = 'Mode: idle'; renderChannel(axTrans, Strans); syncStatus();
    end

    function onClearPicks(~,~)
        Strans.realPts     = zeros(0,2);
        Strans.fakePts     = zeros(0,2);
        Strans.pickHistory = struct('kind',{},'n',{});
        txtMode.String = 'Mode: idle'; renderChannel(axTrans, Strans); syncStatus();
    end

    function onAutoDetect(~,~)
        % Auto-detect: runs detection with guidance picks if present.
        % After this, the user can add REAL/FAKE picks and click Update.
        S = getActiveState(); useG = logical(chkUseGuidance.Value);
        txtMode.String = 'Mode: detecting...'; drawnow;
        try
            if useG && (~isempty(S.realPts)||~isempty(S.fakePts))
                S.params = tuneParamsFromPicks(S, S.params);
            end
            S = runDetection(S, useG);
        catch ME
            errordlg(sprintf('Detection failed:\n%s\n(line %d)', ...
                ME.message, ME.stack(1).line),'Error');
            txtMode.String = 'Mode: idle'; return;
        end
        sldAgg.Value = S.params.aggressiveness;
        if strcmpi(S.channelName,'TRANS') && ~(isscalar(Saf555.detectMask) && Saf555.detectMask)
            Saf555 = runDetection(Saf555, false);
        end
        txtMode.String = 'Mode: idle  (add REAL/FAKE picks then click Update)';
        setActiveState(S);
    end

    function onUpdateDetection(~,~)
        % Exit pick mode if active, then apply picks to detection.
        pickMode = '';
        if ~strcmpi(Strans.channelName,'TRANS')
            warndlg('Update detection only applies to the TRANS channel.','Info');
            return;
        end
        if isempty(Strans.allStats)
            warndlg(['Run >> Auto-detect first, then use + REAL / x FAKE picks ' ...
                'to refine, then click Update.'],'No auto-detection yet');
            return;
        end
        nR = size(Strans.realPts,1);
        nF = size(Strans.fakePts,1);
        if nR == 0 && nF == 0
            warndlg('No picks found. Add + REAL or x FAKE picks first.','No picks');
            return;
        end
        txtMode.String = sprintf('Mode: updating  (%d REAL, %d FAKE)...', nR, nF);
        drawnow;
        try
            Strans = applyPicksToDetection(Strans);
        catch ME
            errordlg(sprintf('Update failed:\n%s\n(line %d)', ...
                ME.message, ME.stack(1).line),'Error');
            txtMode.String = 'Mode: idle'; return;
        end
        % Refresh AF555 tab with new cell outlines
        Saf555 = runDetection(Saf555, false);
        renderChannel(axTrans, Strans);
        renderAF555Tab(axAF555, Strans, Saf555, Iaf555, bgRect);
        renderPunctaCountTab(axCounts, Strans, Saf555, Iaf555, bgRect);
        % Also refresh overlay plots if that tab is visible
        if tg.SelectedTab == tabOver
            renderOverlay(axOver, axHist, axBar, Strans, Saf555, Iaf555, bgRect);
        end
        nCells = sum(Strans.detectMask & ~Strans.deselected);
        txtMode.String = sprintf('Mode: idle  |  %d cells after update (%d added, %d removed)', ...
            nCells, nR, nF);
        syncStatus();
    end

    function onPreviewBW(~,~)
        txtMode.String = 'Mode: computing B&W...'; drawnow;
        try
            BW = computeTransBW(Strans.I, Strans.params);
            Strans.BW = BW;
            showBWDirect(axBW, BW, Strans.params);
            tg.SelectedTab = tabBW;
        catch ME
            errordlg(sprintf('B&W preview failed:\n%s',ME.message),'Error');
        end
        txtMode.String = 'Mode: idle';
    end

    function onPreviewFeat(~,~)
        % Show the raw feature map (before thresholding) as a heatmap.
        % Bright = strong cell response, dark = background.
        % Use this to verify the detector is finding cells before thresholding.
        txtMode.String = 'Mode: computing feature map...'; drawnow;
        try
            feat = computeTransFeature(Strans.I, Strans.params);
            cla(axBW);
            imshow(feat, [], 'Parent', axBW);
            colormap(axBW, hot);
            pctThresh = 95 - 25*Strans.params.sensitivity;
            T = prctile(feat(:), pctThresh);
            title(axBW, sprintf(['Feature map (LoG + dark top-hat)  |  ' ...
                'ringR=%d  sens=%.2f  pctThr=%.0f  T=%.4f  ' ...
                '— bright regions = detected as cells'], ...
                Strans.params.ringRadius, Strans.params.sensitivity, pctThresh, T), ...
                'FontWeight','bold','FontSize',7);
            tg.SelectedTab = tabBW;
        catch ME
            errordlg(sprintf('Feature map preview failed:\n%s\n(line %d)', ...
                ME.message, ME.stack(1).line),'Error');
        end
        txtMode.String = 'Mode: idle';
    end

    function onDeselect(~,~)
        S = getActiveState();
        if isempty(S.detectMask)
            warndlg('Run Auto-detect first.','No detections'); return; end
        ax = getActiveAxes();
        txtMode.String = 'Mode: deselect  (draw polygon; double-click to finish)';
        roi = drawPolyMask(ax, size(S.I));
        if any(roi(:)), S.deselected = S.deselected | pointsInMask(S.centroids,roi); end
        txtMode.String = 'Mode: idle'; setActiveState(S);
    end

    function onResetDeselection(~,~)
        S = getActiveState(); S.deselected(:) = false; setActiveState(S);
    end

    function onShowOverlay(~,~)
        if isempty(Strans.detectMask) || ~any(Strans.detectMask)
            warndlg('Please run Auto-detect on the TRANS channel first.','Missing detections');
            return;
        end
        renderOverlay(axOver, axHist, axBar, Strans, Saf555, Iaf555, bgRect);
        tg.SelectedTab = tabOver;
    end

    function onAnalyse(~,~)
        % Populate the Overlay/Results tab with image, histogram and bar chart.
        % Requires Auto-detect to have been run first.
        % If there are pending REAL/FAKE picks, remind user to click Update first.
        pickMode = '';

        if isempty(Strans.allStats) && isempty(Strans.centroids)
            warndlg('Run >> Auto-detect first, then click Analyse.','No detections yet');
            return;
        end

        % Warn if picks are pending but haven't been applied yet
        nR = size(Strans.realPts,1);
        nF = size(Strans.fakePts,1);
        if nR > 0 || nF > 0
            choice = questdlg( ...
                sprintf(['You have %d REAL and %d FAKE picks pending.\n\n' ...
                         'Click >> Update detection first to apply them,\n' ...
                         'or click "Analyse Anyway" to use the current detection.'], ...
                         nR, nF), ...
                'Pending picks', ...
                'Go back & Update','Analyse Anyway','Go back & Update');
            if ~strcmp(choice,'Analyse Anyway'), return; end
        end

        txtMode.String = 'Analysing...'; drawnow;

        % Refresh AF555 classification
        Saf555 = runDetection(Saf555, false);

        % Render all three overlay panels
        try
            renderChannel(axTrans, Strans);
            renderAF555Tab(axAF555, Strans, Saf555, Iaf555, bgRect);
            renderPunctaCountTab(axCounts, Strans, Saf555, Iaf555, bgRect);
            renderOverlay(axOver, axHist, axBar, Strans, Saf555, Iaf555, bgRect);
        catch ME
            errordlg(sprintf('Render failed:\n%s\n(line %d)', ...
                ME.message, ME.stack(1).line),'Render error');
            txtMode.String = 'Mode: idle'; return;
        end

        tg.SelectedTab = tabOver;
        nCells = sum(Strans.detectMask & ~Strans.deselected);
        bgStr  = '';
        if ~isempty(bgRect)
            bgStr = sprintf('  |  BG=%.4f subtracted', computeBgMean(Iaf555,bgRect));
        end
        txtMode.String = sprintf('Analysis complete  |  %d cells%s', nCells, bgStr);
        syncStatus();
    end

    function onSetBgROI(~,~)
        % Draw a background ROI rectangle on the TRANS image.
        % The selected region is used to estimate background AF555 intensity,
        % which is subtracted from all per-cell measurements.
        tg.SelectedTab = tabTrans; drawnow;
        txtMode.String = 'BG ROI: draw rectangle on blank area  (double-click to confirm)';
        try
            % Use imrect if available, else getrect
            if exist('drawrectangle','file')
                hROI = drawrectangle(axTrans);
                pos  = hROI.Position;   % [x y w h]
                delete(hROI);
            else
                pos = getrect(axTrans);
            end
            if ~isempty(pos) && pos(3)>2 && pos(4)>2
                bgRect = round(pos);
                % Draw persistent cyan rectangle on TRANS axes
                renderChannel(axTrans, Strans);  % redraw clean first
                hold(axTrans,'on');
                rectangle(axTrans,'Position',bgRect,'EdgeColor',[0 1 1], ...
                    'LineWidth',2,'LineStyle','--');
                text(axTrans, bgRect(1)+4, bgRect(2)+12, 'BG region', ...
                    'Color',[0 1 1],'FontSize',8,'FontWeight','bold');
                hold(axTrans,'off');
                % Compute background mean immediately
                bgMean = computeBgMean(Iaf555, bgRect);
                txtMode.String = sprintf('BG ROI set  |  AF555 background mean = %.4f', bgMean);
                % Refresh AF555 tab with updated background
                renderAF555Tab(axAF555, Strans, Saf555, Iaf555, bgRect);
                renderPunctaCountTab(axCounts, Strans, Saf555, Iaf555, bgRect);
            else
                txtMode.String = 'Mode: idle  (no BG region set)';
            end
        catch ME
            txtMode.String = sprintf('BG ROI error: %s', ME.message);
        end
    end

    function onEditParams(~,~)
        S = getActiveState(); p = S.params;
        isTrans = strcmpi(S.channelName,'TRANS');
        if isTrans
            prompt = { ...
                'Ring radius (px) — ~half the cell body radius.  LoG scales = ringR/√2 and ringR×1.4.  Closing disk = ringR×2.5.  TIP: use Preview feature map to tune (try 15–35):', ...
                'Illumination correction sigma (px) — large Gaussian used to estimate and remove the vignette/brightness gradient.  Should be >> cell size.  Try 80–150.  Increase if centre cells are over-detected:', ...
                'Sensitivity (0..1) — threshold percentile: 0.5=85th pct, 1.0=70th pct, 0=95th pct.  Higher = more cells detected (try 0.6–0.8 if cells are missed):', ...
                'Gaussian pre-smooth sigma (px, try 1.0–2.5):', ...
                'Min cell area (px²):', ...
                'Max cell area (px²):', ...
                'Min solidity (0..1, try 0.35–0.55):', ...
                'Min circularity (0..1, 0=off, try 0.05–0.15):', ...
                'Opening radius — removes thin debris (px, try 2–5):', ...
                'Watershed min distance (px, try 10–20):'};
            def = {num2str(p.ringRadius), ...
                   num2str(p.topHatRadius), ...
                   num2str(p.sensitivity), ...
                   num2str(p.gaussSigma), ...
                   num2str(p.minArea),     num2str(p.maxArea), ...
                   num2str(p.minSolidity), num2str(p.minCircularity), ...
                   num2str(p.openRadius),  num2str(p.watershedMinDist)};
            answ = inputdlg(prompt,'Edit TRANS params (LoG + illumination correction)',[1 82],def);
            if isempty(answ), return; end
            p.ringRadius       = str2double(answ{1});
            p.topHatRadius     = str2double(answ{2});
            p.sensitivity      = str2double(answ{3});
            p.gaussSigma       = str2double(answ{4});
            p.minArea          = str2double(answ{5});
            p.maxArea          = str2double(answ{6});
            p.minSolidity      = str2double(answ{7});
            p.minCircularity   = str2double(answ{8});
            p.openRadius       = str2double(answ{9});
            p.watershedMinDist = str2double(answ{10});
        else
            msgbox(sprintf(['AF555 scoring now uses fixed object-level puncta parameters.\n\n' ...
                            'Edit defaultParams(''fluor'') in the code to tune them.\n\n' ...
                            'Current activity cutoff: %.1f%% puncta area / cell area'], ...
                            100*p.punctaFractionThreshold), ...
                   'AF555 puncta params');
            return;
        end
        p = sanitizeParams(p, S.channelName);
        p = applyAggressiveness(p);
        S.params = p; sldAgg.Value = p.aggressiveness; setActiveState(S);
    end

    function onSaveParamsNow(~,~)
        [f,fp] = uiputfile('params_*.mat','Save params');
        if isequal(f,0), return; end
        paramsOut = struct('trans',Strans.params,'af555',Saf555.params); %#ok<NASGU>
        save(fullfile(fp,f),'paramsOut');
        msgbox('Params saved.','Saved');
    end

    function onSaveAndExit(~,~)
        if isempty(Strans.detectMask) || (~islogical(Saf555.detectMask) || ~Saf555.detectMask)
            c = questdlg('Run Auto-detect on TRANS first (AF555 is set automatically). Save anyway?', ...
                'Warning','Save anyway','Cancel','Cancel');
            if ~strcmp(c,'Save anyway'), return; end
        end

        % --- Package trans channel ---
        results.trans = packageChannel(Strans);

        % --- Score each TRANS cell using object-level AF555 puncta ---
        puncta = analyzePunctaInTransCells(Strans, Saf555, Iaf555, bgRect);
        isActive = puncta.isActive;

        results.count_total_cells    = results.trans.finalCount;
        results.count_phago_cells    = sum(isActive);
        results.fraction_phago       = safeRatio(results.count_phago_cells, results.count_total_cells);
        results.percent_phago        = results.fraction_phago * 100;
        results.per_cell_puncta_fraction = puncta.punctaFraction;
        results.per_cell_puncta_area     = puncta.punctaArea;
        results.per_cell_area            = puncta.cellArea;
        results.per_cell_puncta_count    = puncta.punctaCount;
        results.active_cell_mask     = isActive;
        results.per_cell_table       = makePerCellPunctaTable(puncta, isActive);
        results.puncta               = packagePunctaAnalysis(puncta);

        ts = datestr(now,'yyyymmdd_HHMMSS');
        [bp,bn,~] = fileparts(transFull);
        [f,fp] = uiputfile('*.mat','Save results', ...
            fullfile(bp, sprintf('%s_phago_results_%s.mat',bn,ts)));
        if isequal(f,0), return; end
        matPath = fullfile(fp,f);
        save(matPath,'results');

        [~,saveBase,~] = fileparts(matPath);
        csvPath = fullfile(fp, [saveBase '_per_cell_puncta.csv']);
        try
            writetable(results.per_cell_table, csvPath);
        catch ME
            warning('Could not write per-cell CSV: %s', ME.message);
        end

        fprintf('\n=== Macrophage Phagocytosis Results (object-level puncta) ===\n');
        fprintf('Total macrophages (TRANS):      %d\n',  results.count_total_cells);
        fprintf('Phagocytically active (puncta): %d\n',  results.count_phago_cells);
        fprintf('Fraction active:                %.4f\n', results.fraction_phago);
        fprintf('Percent active:                 %.2f%%\n', results.percent_phago);
        fprintf('Activity cutoff:                %.2f%% puncta/cell area\n\n', ...
            100*puncta.params.punctaFractionThreshold);

        msgbox(sprintf(['Total cells:     %d\n' ...
                        'Active (puncta): %d\n' ...
                        'Active %%:        %.1f%%\n' ...
                        'Cutoff:          %.1f%% puncta area\n' ...
                        'Per-cell table:  saved in results.per_cell_table\n' ...
                        'CSV:             %s'], ...
            results.count_total_cells, results.count_phago_cells, ...
            results.percent_phago, 100*puncta.params.punctaFractionThreshold, ...
            csvPath), ...
            'Phagocytosis Results');

        uiresume(hFig); delete(hFig);
    end

    function onCloseRequest(~,~)
        c = questdlg('Close without saving?','Exit','Close','Cancel','Cancel');
        if strcmp(c,'Close'), results = []; uiresume(hFig); delete(hFig); end
    end

    function syncStatus()
        S = getActiveState();
        % detectMask for AF555 is scalar sentinel, handle both
        if isscalar(S.detectMask)
            det = double(S.detectMask);
            fin = double(S.detectMask);
        else
            det = sum(S.detectMask);
            fin = sum(S.detectMask & ~S.deselected);
        end

        % Always read pick counts from Strans directly (picks bypass setActiveState)
        nRP = size(Strans.realPts,1);
        nFP = size(Strans.fakePts,1);

        % Compute active stats live if TRANS has been detected
        activeStr = '';
        transReady = ~isempty(Strans.detectMask) && numel(Strans.detectMask)>0 && any(Strans.detectMask);
        af555Ready = isscalar(Saf555.detectMask) && Saf555.detectMask;
        if transReady && af555Ready
            try
                puncta = analyzePunctaInTransCells(Strans, Saf555, Iaf555, bgRect);
                isAct = puncta.isActive;
                nTot = numel(isAct);
                nAct = sum(isAct);
                medFrac = 100*median(puncta.punctaFraction);
                activeStr = sprintf(['\n--- Phago summary ---\n' ...
                    'Total cells:  %d\nActive cells: %d\n' ...
                    'Active %%:    %.1f%%\nMedian puncta: %.1f%%'], ...
                    nTot, nAct, safeRatio(nAct,nTot)*100, medFrac);
            catch
            end
        end

        % Pick hint — prompt user to click Update if there are pending picks
        pickHint = '';
        if nRP>0 || nFP>0
            pickHint = sprintf('\n[R:%d F:%d pending → Update]', nRP, nFP);
        end

        txtCounts.String = sprintf([ ...
            'Channel:      %s\n' ...
            'Aggress.:     %.2f\n' ...
            'REAL picks:   %d\n' ...
            'FAKE picks:   %d\n' ...
            'Detected:     %d\n' ...
            'After desel.: %d%s%s'], ...
            S.channelName, S.params.aggressiveness, ...
            nRP, nFP, det, fin, pickHint, activeStr);
    end

end % ---- end main function ----


% =======================================================================
%  OBJECT-LEVEL AF555 PUNCTA ANALYSIS
%
%  PunctaFinder-lite adaptation:
%    1. Keep TRANS masks as the only cell boundaries.
%    2. Background-correct AF555.
%    3. Find punctum-sized local-maxima candidates from a spot-enhanced image.
%    4. Score each candidate disk against its surrounding ring and cell signal.
%    5. Suppress duplicate/overlapping candidates.
%    6. Build final puncta area from accepted candidate objects.
% =======================================================================
function puncta = analyzePunctaInTransCells(Strans, Saf555, Iaf555, bgRect)
if nargin < 4, bgRect = []; end

p = sanitizeParams(Saf555.params,'fluor');
[nr,nc] = size(Iaf555);
cells = collectTransCells(Strans, [nr nc]);
nCells = numel(cells);

puncta.params         = p;
puncta.bgMean        = computeBgMean(Iaf555, bgRect);
puncta.cells         = cells;
puncta.cellArea      = zeros(nCells,1);
puncta.punctaArea    = zeros(nCells,1);
puncta.punctaFraction= zeros(nCells,1);
puncta.punctaCount   = zeros(nCells,1);
puncta.isActive      = false(nCells,1);
puncta.centroids     = zeros(nCells,2);
puncta.punctaMaskUnion = false(nr,nc);
puncta.correctedAF555  = [];
puncta.spotEnhancedAF555 = [];

if nCells == 0, return; end

Icorr = max(0, Iaf555 - puncta.bgMean);
Idetect = Icorr;
if p.punctaSmoothSigma > 0
    Idetect = imgaussfilt(Idetect, p.punctaSmoothSigma);
end
if p.punctaTopHatRadius > 0
    Ispot = imtophat(Idetect, strel('disk', p.punctaTopHatRadius));
else
    Ispot = Idetect;
end

puncta.correctedAF555 = Icorr;
puncta.spotEnhancedAF555 = Ispot;
globalMaxima = imregionalmax(Ispot);

for ci = 1:nCells
    cellMask = cells(ci).mask;
    cellArea = nnz(cellMask);
    puncta.cellArea(ci) = cellArea;
    puncta.centroids(ci,:) = cells(ci).centroid;
    if cellArea == 0, continue; end

    cellRawVals  = double(Icorr(cellMask));
    cellSpotVals = double(Ispot(cellMask));
    cellMean     = mean(cellRawVals);
    cellMedian   = median(cellRawVals);
    cellMAD      = robustMad(cellRawVals);
    spotMedian   = median(cellSpotVals);
    spotMAD      = robustMad(cellSpotVals);

    spotFloor = max(p.punctaMinSpotResponse, ...
                    spotMedian + p.punctaCandidateMADFactor*spotMAD);
    candidateMask = globalMaxima & cellMask & (Ispot >= spotFloor);
    [candY, candX] = find(candidateMask);
    if isempty(candX), continue; end

    candScore = Ispot(candidateMask);
    [~,ord] = sort(candScore, 'descend');
    maxCand = min(numel(ord), p.punctaMaxCandidatesPerCell);
    ord = ord(1:maxCand);

    candidates = struct('x',{},'y',{},'score',{},'localRatio',{}, ...
                        'cellRatio',{},'cv',{},'areaMask',{});

    for jj = 1:numel(ord)
        cx = candX(ord(jj));
        cy = candY(ord(jj));

        diskIdx = diskIndices([nr nc], cx, cy, p.punctaCandidateRadius, cellMask);
        ringIdx = annulusIndices([nr nc], cx, cy, ...
            p.punctaRingInnerRadius, p.punctaRingOuterRadius, cellMask);
        if numel(diskIdx) < max(3,p.punctaMinArea) || numel(ringIdx) < 5
            continue;
        end

        diskVals = double(Icorr(diskIdx));
        ringVals = double(Icorr(ringIdx));
        candMean = mean(diskVals);
        ringMean = mean(ringVals);
        localRatio = candMean / max(ringMean, p.punctaRatioEps);
        cellRatio  = candMean / max(cellMean, p.punctaRatioEps);
        candCV     = std(diskVals) / max(candMean, p.punctaRatioEps);

        if candMean < p.punctaMinRawIntensity, continue; end
        if localRatio < p.punctaLocalRatio, continue; end
        if cellRatio  < p.punctaCellRatio,  continue; end
        if candCV > p.punctaMaxCV, continue; end

        areaIdx = diskIndices([nr nc], cx, cy, p.punctaAreaRadius, cellMask);
        if isempty(areaIdx), continue; end
        areaRawThr = max([p.punctaMinRawIntensity, ...
                          ringMean*p.punctaAreaLocalRatio, ...
                          cellMedian + p.punctaAreaMADFactor*cellMAD]);
        areaSpotThr = max(p.punctaMinSpotResponse, ...
                          spotMedian + p.punctaAreaSpotMADFactor*spotMAD);
        pass = Icorr(areaIdx) >= areaRawThr & Ispot(areaIdx) >= areaSpotThr;
        areaMask = false(nr,nc);
        areaMask(areaIdx(pass)) = true;
        areaMask = componentAtOrNear(areaMask, cx, cy);
        areaPix = nnz(areaMask);
        if areaPix < p.punctaMinArea || areaPix > p.punctaMaxArea
            continue;
        end

        c.score      = candMean * localRatio * cellRatio;
        c.x          = cx;
        c.y          = cy;
        c.localRatio = localRatio;
        c.cellRatio  = cellRatio;
        c.cv         = candCV;
        c.areaMask   = areaMask;
        candidates(end+1) = c; %#ok<AGROW>
    end

    if isempty(candidates), continue; end
    [~,ord] = sort([candidates.score], 'descend');
    candidates = candidates(ord);

    kept = false(1,numel(candidates));
    keptCenters = zeros(0,2);
    for jj = 1:numel(candidates)
        ctr = [candidates(jj).x candidates(jj).y];
        if isempty(keptCenters)
            keepThis = true;
        else
            d = sqrt(sum((keptCenters - ctr).^2, 2));
            keepThis = all(d >= p.punctaSuppressionRadius);
        end
        if keepThis
            kept(jj) = true;
            keptCenters(end+1,:) = ctr; %#ok<AGROW>
        end
    end

    finalCellPuncta = false(nr,nc);
    keptCandidates = candidates(kept);
    for jj = 1:numel(keptCandidates)
        finalCellPuncta = finalCellPuncta | keptCandidates(jj).areaMask;
    end
    finalCellPuncta = finalCellPuncta & cellMask;

    if ~isempty(keptCandidates)
        keptCandidateSummary = rmfield(keptCandidates, 'areaMask');
    else
        keptCandidateSummary = keptCandidates;
    end

    puncta.cells(ci).punctaMask = finalCellPuncta;
    puncta.cells(ci).candidates = keptCandidateSummary;
    puncta.punctaMaskUnion = puncta.punctaMaskUnion | finalCellPuncta;
    puncta.punctaArea(ci) = nnz(finalCellPuncta);
    puncta.punctaFraction(ci) = safeRatio(puncta.punctaArea(ci), cellArea);
    puncta.punctaCount(ci) = numel(keptCandidates);
    puncta.isActive(ci) = puncta.punctaFraction(ci) > p.punctaFractionThreshold;
end
end


% =======================================================================
%  TRANS CELL COLLECTION
%  Rebuilds filled masks from TRANS boundaries, then matches each boundary
%  to its final centroid so metrics/labels/outline colors stay aligned.
% =======================================================================
function cells = collectTransCells(Strans, imgSize)
cells = struct('mask',{},'boundary',{},'centroid',{},'area',{}, ...
               'punctaMask',{},'candidates',{});
if isempty(Strans.detectMask) || isscalar(Strans.detectMask)
    return;
end

finalMask = Strans.detectMask & ~Strans.deselected;
if ~any(finalMask), return; end
targetCents = Strans.centroids(finalMask,:);

nr = imgSize(1); nc = imgSize(2);
bounds = Strans.boundaries;
boundMasks = {};
boundBoundaries = {};
boundCents = zeros(0,2);
boundAreas = zeros(0,1);
for k = 1:numel(bounds)
    b = bounds{k};
    if isempty(b), continue; end
    m = poly2mask(b(:,2), b(:,1), nr, nc);
    if ~any(m(:)), continue; end
    CC = bwconncomp(m);
    if CC.NumObjects > 1
        sz = cellfun(@numel, CC.PixelIdxList);
        [~,bi] = max(sz);
        m2 = false(nr,nc);
        m2(CC.PixelIdxList{bi}) = true;
        m = m2;
    end
    st = regionprops(m,'Area','Centroid');
    if isempty(st), continue; end
    boundMasks{end+1} = m; %#ok<AGROW>
    boundBoundaries{end+1} = b; %#ok<AGROW>
    boundCents(end+1,:) = st(1).Centroid; %#ok<AGROW>
    boundAreas(end+1,1) = st(1).Area; %#ok<AGROW>
end
if isempty(boundMasks), return; end

used = false(numel(boundMasks),1);
for i = 1:size(targetCents,1)
    cx = min(max(round(targetCents(i,1)),1),nc);
    cy = min(max(round(targetCents(i,2)),1),nr);

    contains = false(numel(boundMasks),1);
    for bidx = 1:numel(boundMasks)
        contains(bidx) = ~used(bidx) && boundMasks{bidx}(cy,cx);
    end

    avail = find(~used);
    if any(contains)
        cand = find(contains);
        d = sqrt(sum((boundCents(cand,:) - targetCents(i,:)).^2,2));
        [~,bestLocal] = min(d);
        best = cand(bestLocal);
    elseif ~isempty(avail)
        d = sqrt(sum((boundCents(avail,:) - targetCents(i,:)).^2,2));
        [~,bestLocal] = min(d);
        best = avail(bestLocal);
    else
        break;
    end

    used(best) = true;
    c.mask       = boundMasks{best};
    c.boundary   = boundBoundaries{best};
    c.centroid   = boundCents(best,:);
    c.area       = boundAreas(best);
    c.punctaMask = false(nr,nc);
    c.candidates = struct('x',{},'y',{},'score',{},'localRatio',{}, ...
                          'cellRatio',{},'cv',{},'areaMask',{});
    cells(end+1) = c; %#ok<AGROW>
end
end


function idx = diskIndices(sz, cx, cy, radius, limitMask)
nr = sz(1); nc = sz(2);
r1 = max(1, round(cy-radius)); r2 = min(nr, round(cy+radius));
c1 = max(1, round(cx-radius)); c2 = min(nc, round(cx+radius));
[xx,yy] = meshgrid(c1:c2, r1:r2);
inDisk = (xx-cx).^2 + (yy-cy).^2 <= radius^2;
rr = yy(inDisk); cc = xx(inDisk);
idx = sub2ind([nr nc], rr(:), cc(:));
if nargin >= 5 && ~isempty(limitMask)
    idx = idx(limitMask(idx));
end
end


function idx = annulusIndices(sz, cx, cy, innerRadius, outerRadius, limitMask)
nr = sz(1); nc = sz(2);
r1 = max(1, round(cy-outerRadius)); r2 = min(nr, round(cy+outerRadius));
c1 = max(1, round(cx-outerRadius)); c2 = min(nc, round(cx+outerRadius));
[xx,yy] = meshgrid(c1:c2, r1:r2);
d2 = (xx-cx).^2 + (yy-cy).^2;
inRing = d2 >= innerRadius^2 & d2 <= outerRadius^2;
rr = yy(inRing); cc = xx(inRing);
idx = sub2ind([nr nc], rr(:), cc(:));
if nargin >= 6 && ~isempty(limitMask)
    idx = idx(limitMask(idx));
end
end


function objMask = componentAtOrNear(BW, cx, cy)
objMask = false(size(BW));
CC = bwconncomp(BW);
if CC.NumObjects == 0, return; end
L = labelmatrix(CC);
cy = min(max(round(cy),1),size(BW,1));
cx = min(max(round(cx),1),size(BW,2));
lbl = L(cy,cx);
if lbl > 0
    objMask(CC.PixelIdxList{lbl}) = true;
    return;
end

st = regionprops(CC,'Centroid');
cents = reshape([st.Centroid],2,[])';
d = sqrt((cents(:,1)-cx).^2 + (cents(:,2)-cy).^2);
[~,best] = min(d);
objMask(CC.PixelIdxList{best}) = true;
end


function m = robustMad(vals)
vals = double(vals(:));
if isempty(vals)
    m = 0;
else
    medv = median(vals);
    m = median(abs(vals - medv));
end
end


function out = packagePunctaAnalysis(puncta)
out = rmfield(puncta, {'cells','correctedAF555','spotEnhancedAF555'});
out.cellCentroids = puncta.centroids;
out.note = ['Object-level puncta scoring: candidate local maxima, local ring ratio, ' ...
            'whole-cell ratio, CV gate, duplicate suppression, area from accepted objects.'];
end


function T = makePerCellPunctaTable(puncta, isActive)
n = numel(puncta.punctaFraction);
CellID = (1:n)';
CentroidX = puncta.centroids(:,1);
CentroidY = puncta.centroids(:,2);
PunctaFraction = puncta.punctaFraction(:);
PunctaPercent = 100 * PunctaFraction;
PunctaAreaPx = puncta.punctaArea(:);
CellAreaPx = puncta.cellArea(:);
PunctaCount = puncta.punctaCount(:);
Active = logical(isActive(:));
ActivityCutoffPercent = repmat(100*puncta.params.punctaFractionThreshold, n, 1);

T = table(CellID, CentroidX, CentroidY, PunctaFraction, PunctaPercent, ...
    PunctaAreaPx, CellAreaPx, PunctaCount, Active, ActivityCutoffPercent);
end


% =======================================================================
%  PUNCTA COUNT OVERLAY
% =======================================================================
function renderPunctaCountTab(ax, Strans, Saf555, Iaf555, bgRect)
if nargin < 5, bgRect = []; end
imshow(Iaf555, [], 'Parent', ax); hold(ax,'on');

if ~isempty(bgRect)
    rectangle(ax,'Position',bgRect,'EdgeColor',[0 1 1], ...
        'LineWidth',2,'LineStyle','--');
    bgMeanV = computeBgMean(Iaf555, bgRect);
    text(ax,bgRect(1)+4,bgRect(2)+12, sprintf('BG=%.4f',bgMeanV), ...
        'Color',[0 1 1],'FontSize',7,'FontWeight','bold');
end

if isempty(Strans.detectMask) || isscalar(Strans.detectMask) || ~any(Strans.detectMask)
    title(ax, 'Puncta counts — run TRANS Auto-detect first', ...
        'FontWeight','bold');
    hold(ax,'off'); return;
end

finalMask = Strans.detectMask & ~Strans.deselected;
if ~any(finalMask)
    title(ax, 'Puncta counts — no accepted TRANS cell boundaries', ...
        'FontWeight','bold');
    hold(ax,'off'); return;
end

puncta = analyzePunctaInTransCells(Strans, Saf555, Iaf555, bgRect);
counts = puncta.punctaCount;
nCells = numel(counts);
nWithPuncta = sum(counts > 0);
totalPuncta = sum(counts);

if any(puncta.punctaMaskUnion(:))
    mag = cat(3, ones(size(Iaf555)), zeros(size(Iaf555)), ones(size(Iaf555)));
    hP = imshow(mag, 'Parent', ax);
    set(hP, 'AlphaData', 0.70*puncta.punctaMaskUnion);
end

for k = 1:nCells
    b = puncta.cells(k).boundary;
    if isempty(b), continue; end
    if counts(k) > 0
        plot(ax,b(:,2),b(:,1),'-','Color',[0.1 1 0.2],'LineWidth',2.0);
    else
        plot(ax,b(:,2),b(:,1),'w-','LineWidth',1.0);
    end
end

for i = 1:nCells
    c = puncta.cells(i).centroid;
    if counts(i) > 0
        labelColor = [1 0.9 0];
        labelWeight = 'bold';
    else
        labelColor = [0.85 0.95 1];
        labelWeight = 'normal';
    end
    text(ax,c(1)+4,c(2),sprintf('%d',counts(i)), ...
        'Color',labelColor,'FontSize',8,'FontWeight',labelWeight);
end

bgLbl = ''; if puncta.bgMean>0, bgLbl = sprintf('  |  BG=%.4f',puncta.bgMean); end
title(ax, sprintf('AF555 puncta count in TRANS masks%s  |  Cells: %d  |  >0 puncta: %d  |  Total puncta: %d', ...
    bgLbl, nCells, nWithPuncta, totalPuncta), ...
    'FontWeight','bold','FontSize',8);
hold(ax,'off');
end


% =======================================================================
%  OVERLAY RENDERING
% =======================================================================
function renderOverlay(axImg, axHist, axBar, Strans, Saf555, Iaf555, bgRect)

puncta = analyzePunctaInTransCells(Strans, Saf555, Iaf555, bgRect);
isActive = puncta.isActive;
fractions = puncta.punctaFraction;
nTot = numel(isActive);
nAct = sum(isActive);
nInact = nTot - nAct;

% =========================================================
% PANEL 1 — Overlay image (left)
% =========================================================
imshow(Strans.I,[],'Parent',axImg); hold(axImg,'on');
if any(puncta.punctaMaskUnion(:))
    mag = cat(3, ones(size(Iaf555)), zeros(size(Iaf555)), ones(size(Iaf555)));
    hP = imshow(mag, 'Parent', axImg);
    set(hP, 'AlphaData', 0.70*puncta.punctaMaskUnion);
end

if ~isempty(bgRect)
    rectangle(axImg,'Position',bgRect,'EdgeColor',[0 1 1], ...
        'LineWidth',2,'LineStyle','--');
    text(axImg,bgRect(1)+4,bgRect(2)+12,'BG','Color',[0 1 1], ...
        'FontSize',8,'FontWeight','bold');
end

for k = 1:numel(puncta.cells)
    b = puncta.cells(k).boundary;
    if isempty(b), continue; end
    if k<=numel(isActive) && isActive(k)
        plot(axImg,b(:,2),b(:,1),'-','Color',[0.05 1 0.15],'LineWidth',1.8);
    else
        plot(axImg,b(:,2),b(:,1),'w-','LineWidth',1.0);
    end
end

for i = 1:nTot
    c = puncta.cells(i).centroid;
    if isActive(i)
        labelColor = [1 0.9 0];
        labelWeight = 'bold';
    else
        labelColor = [0.85 0.95 1];
        labelWeight = 'normal';
    end
    text(axImg,c(1)+4,c(2),sprintf('%.2f%%',100*fractions(i)), ...
        'Color',labelColor,'FontSize',6.5,'FontWeight',labelWeight);
end

bgStr = '';
if puncta.bgMean > 0, bgStr = sprintf('  |  BG=%.4f subtracted', puncta.bgMean); end
title(axImg, sprintf('Object-level AF555 puncta  |  Total: %d  |  Active: %d  |  %.1f%%%s', ...
    nTot, nAct, safeRatio(nAct,nTot)*100, bgStr), ...
    'FontWeight','bold','FontSize',8);
hold(axImg,'off');

% =========================================================
% PANEL 2 — Puncta-fraction histogram (top right)
% =========================================================
cla(axHist);
if nTot > 0
    valsPct = 100*fractions;
    cutoffPct = 100*puncta.params.punctaFractionThreshold;
    maxPct = max([valsPct(:); cutoffPct; 1]);
    binEdges = linspace(0, maxPct*1.10 + eps, min(20, max(6,nTot+2)));

    hold(axHist,'on');
    histogram(axHist, valsPct(~isActive), binEdges, ...
        'FaceColor',[0.5 0.5 1],'EdgeColor','none','FaceAlpha',0.75);
    histogram(axHist, valsPct(isActive), binEdges, ...
        'FaceColor',[0.1 0.85 0.1],'EdgeColor','none','FaceAlpha',0.75);
    xline(axHist, cutoffPct, 'r--','LineWidth',1.5);
    hold(axHist,'off');

    xlabel(axHist,'Puncta area / TRANS cell area (%)','FontSize',7);
    ylabel(axHist,'Cell count','FontSize',7);
    title(axHist,'Puncta fraction distribution','FontSize',8,'FontWeight','bold');
    legend(axHist,{'Inactive','Active','Cutoff'},'FontSize',6,'Location','northeast');
    axHist.FontSize = 7;
    grid(axHist,'on'); box(axHist,'on');
else
    text(axHist,0.5,0.5,'No cells detected','Units','normalized', ...
        'HorizontalAlignment','center','FontSize',9);
end

% =========================================================
% PANEL 3 — Bar chart: cell counts (bottom right)
% =========================================================
cla(axBar);
if nTot > 0
    barData = [nInact, nAct];
    bh = bar(axBar, barData, 0.5);
    bh.FaceColor = 'flat';
    bh.CData     = [0.5 0.5 1; 0.1 0.85 0.1];
    bh.EdgeColor = 'none';

    set(axBar,'XTickLabel',{'Inactive','Active'},'FontSize',7.5);
    ylabel(axBar,'# cells','FontSize',7);
    title(axBar, sprintf('Cell counts  |  Active: %.1f%%', ...
        safeRatio(nAct,nTot)*100),'FontSize',8,'FontWeight','bold');

    hold(axBar,'on');
    text(axBar,1, nInact + 0.3, num2str(nInact), ...
        'HorizontalAlignment','center','FontSize',9,'FontWeight','bold');
    text(axBar,2, nAct   + 0.3, num2str(nAct),   ...
        'HorizontalAlignment','center','FontSize',9,'FontWeight','bold');
    hold(axBar,'off');

    ylim(axBar,[0 max(nTot * 1.25, 5)]);
    grid(axBar,'on'); box(axBar,'on');
else
    text(axBar,0.5,0.5,'No cells detected','Units','normalized', ...
        'HorizontalAlignment','center','FontSize',9);
end
end


% -----------------------------------------------------------------------
%  Compute mean AF555 background intensity from a rectangular ROI
%  bgRect = [x y w h] in image pixel coordinates
% -----------------------------------------------------------------------
function bgMean = computeBgMean(Iaf555, bgRect)
bgMean = 0;
if isempty(bgRect), return; end
[nr,nc] = size(Iaf555);
x1 = max(1,   round(bgRect(1)));
y1 = max(1,   round(bgRect(2)));
x2 = min(nc,  round(bgRect(1)+bgRect(3)-1));
y2 = min(nr,  round(bgRect(2)+bgRect(4)-1));
if x2<=x1 || y2<=y1, return; end
patch  = Iaf555(y1:y2, x1:x2);
bgMean = mean(patch(:));
end


% =======================================================================
%  DETECTION DISPATCHER
% =======================================================================
function S = runDetection(S, useGuidance)
if strcmpi(S.channelName,'TRANS')
    S = runDetectionTrans(S, useGuidance);
else
    S = runDetectionFluor(S, useGuidance);
end
end


% =======================================================================
%  TRANS DETECTION  (same B&W pipeline as rbc_wbc_ratio_ui_v6_bw)
% =======================================================================
function S = runDetectionTrans(S, useGuidance)
I = S.I; p = S.params;
[nr,nc] = size(I);

BW = computeTransBW(I, p);
S.BW = BW;

% Watershed
D  = -bwdist(~BW);
D(~BW) = -Inf;
D  = imhmin(D, p.watershedMinDist);
L  = watershed(D);
BW(L==0) = false;

CC    = bwconncomp(BW);
stats = regionprops(CC,'Area','Solidity','Eccentricity','Centroid', ...
                       'Perimeter','PixelIdxList');

keep = true(numel(stats),1);
for i = 1:numel(stats)
    a = stats(i).Area; s = stats(i).Solidity;
    if a < p.minArea || a > p.maxArea,  keep(i)=false; continue; end
    if s < p.minSolidity,               keep(i)=false; continue; end
    if p.minCircularity > 0 && stats(i).Perimeter > 0
        if 4*pi*a/stats(i).Perimeter^2 < p.minCircularity
            keep(i) = false; continue; end
    end
end

% Save ALL morphology-passing candidates so Update detection can apply
% picks without re-running the full pipeline.
S.allStats = stats(keep);

% Apply REAL/FAKE guidance picks if enabled
if useGuidance && (~isempty(S.realPts)||~isempty(S.fakePts))
    C   = reshape([stats.Centroid],2,[])';
    idx = find(keep);
    if ~isempty(idx)
        Ck    = C(idx,:);
        dPick = max(8, 0.012*hypot(nr,nc));
        if ~isempty(S.realPts)
            dR = safe_pdist2(Ck,S.realPts);
            keep(idx(min(dR,[],2)<=dPick)) = true;
        end
        if ~isempty(S.fakePts)
            dF = safe_pdist2(Ck,S.fakePts);
            keep(idx(min(dF,[],2)<=dPick)) = false;
        end
    end
end

keptStats = stats(keep);
S.detectMask = true(numel(keptStats),1);
if isempty(keptStats)
    S.centroids=zeros(0,2); S.deselected=false(0,1); S.boundaries={}; return; end

S.centroids  = reshape([keptStats.Centroid],2,[])';
S.deselected = false(numel(keptStats),1);
BWk = false(nr,nc);
for i = 1:numel(keptStats), BWk(keptStats(i).PixelIdxList)=true; end
S.boundaries = bwboundaries(BWk);
end


% =======================================================================
%  AF555 "DETECTION"  — no independent blob detection needed.
%  The AF555 channel is measured within TRANS cell masks.
%  This function simply marks the channel as "ready" (detectMask = scalar
%  true sentinel) so the UI knows it has been processed.
%  AF555 puncta scoring is run inside TRANS masks during analysis/rendering.
% =======================================================================
function S = runDetectionFluor(S, ~)
% Nothing to segment — just confirm channel is ready.
S.detectMask = true;   % sentinel: channel is ready for intensity measurement
S.centroids  = zeros(0,2);
S.deselected = false(0,1);
S.boundaries = {};
end


% =======================================================================
%  APPLY PICKS TO EXISTING DETECTION  (fast — no BW recompute)
%
%  Starting from S.allStats (all morphology-passing blobs from the last
%  Auto-detect run):
%    • Every blob is KEPT by default
%    • A blob NEAR a FAKE pick  → removed
%    • Any REAL pick with NO nearby blob → a circular synthetic region is
%      added at that location (radius = sqrt(median area / pi))
%
%  "Near" = within dPick pixels (1.2% of image diagonal, min 10px).
% =======================================================================
function S = applyPicksToDetection(S)
[nr, nc] = size(S.I);
stats     = S.allStats;
nAll      = numel(stats);
keep      = true(nAll, 1);
dPick     = max(10, 0.012*hypot(nr,nc));

if nAll > 0
    C = reshape([stats.Centroid],2,[])';

    % Remove blobs near FAKE picks
    if ~isempty(S.fakePts)
        dF = safe_pdist2(C, S.fakePts);
        keep(min(dF,[],2) <= dPick) = false;
    end

    % REAL picks: ensure any blob near them stays kept
    % (they may have been flagged by a FAKE pick in a different session)
    if ~isempty(S.realPts)
        dR = safe_pdist2(C, S.realPts);
        keep(min(dR,[],2) <= dPick) = true;
    end
end

keptStats = stats(keep);

% ---- Synthetic cell regions for REAL picks with no nearby auto-blob ----
%
% Profile from existing cells:
%   medRadius = sqrt(median(area) / pi)  — expected cell radius
%   We search within 1×medRadius of the click for dark pixels,
%   threshold them, and take only the connected component that contains
%   the click point (or the darkest pixel nearest it).
%   The resulting mask is HARD-CAPPED to a disk of medRadius so it can
%   never be larger than a typical auto-detected cell.

% Build median profile from allStats (all morphology-passing blobs)
medArea   = 3000;   % sensible fallback (px²)
medRadius = 30;     % fallback radius (px)
if nAll > 0
    areas     = [stats.Area];
    medArea   = median(areas);
    medRadius = round(sqrt(medArea / pi));
end
% Hard cap: search radius = medRadius, cell can't exceed medRadius
searchR   = max(10, medRadius);

extraStats = struct('Area',{},'Solidity',{},'Eccentricity',{}, ...
                    'Centroid',{},'Perimeter',{},'PixelIdxList',{});

if ~isempty(S.realPts)
    % Pre-compute feature map once (highlights dark cell bodies)
    feat = computeTransFeature(S.I, S.params);
    % Normalise to [0,1]
    fMin = min(feat(:)); fMax = max(feat(:));
    if fMax > fMin, feat = (feat - fMin)/(fMax - fMin); end

    for ri = 1:size(S.realPts,1)
        cx = round(S.realPts(ri,1));
        cy = round(S.realPts(ri,2));
        cx = min(max(cx,1),nc); cy = min(max(cy,1),nr);

        % Skip if an auto-detected blob already covers this pick
        if ~isempty(keptStats)
            Ck = reshape([keptStats.Centroid],2,[])';
            if min(sqrt(sum((Ck - [cx cy]).^2,2))) <= searchR*1.2
                continue;
            end
        end

        % Extract local window exactly searchR around the click
        r1 = max(1, cy-searchR); r2 = min(nr, cy+searchR);
        c1 = max(1, cx-searchR); c2 = min(nc, cx+searchR);
        localFeat = feat(r1:r2, c1:c2);

        % Threshold: keep top 35% of feature response in the window
        % (these are the bright/dark cell-body pixels in the feature map)
        T = prctile(localFeat(:), 65);
        T = max(T, 0.10);   % never threshold below 10% of normalised range
        localBW = localFeat >= T;

        % Clean up: close gaps, fill holes, remove tiny specks
        closeR  = max(2, round(medRadius * 0.15));
        localBW = imclose(localBW, strel('disk', closeR));
        localBW = imfill(localBW, 'holes');
        localBW = bwareaopen(localBW, max(5, round(medArea * 0.04)));

        % Click position in local coords
        lcx = max(1, min(cx - c1 + 1, c2-c1+1));
        lcy = max(1, min(cy - r1 + 1, r2-r1+1));

        % Pick the connected component that contains the click point.
        % If the click landed on background, pick the component whose
        % centroid is closest to the click.
        CC_local      = bwconncomp(localBW);
        cellMaskLocal = false(size(localBW));
        if CC_local.NumObjects > 0
            L_local = labelmatrix(CC_local);
            lbl     = L_local(lcy, lcx);
            if lbl > 0
                cellMaskLocal = (L_local == lbl);
            else
                % Nothing at click — pick component with centroid nearest click
                st_loc = regionprops(CC_local,'Centroid','PixelIdxList');
                ctrs   = reshape([st_loc.Centroid],2,[])';  % [x y] per row
                dists  = sqrt((ctrs(:,1)-lcx).^2 + (ctrs(:,2)-lcy).^2);
                [~,bi] = min(dists);
                cellMaskLocal(st_loc(bi).PixelIdxList) = true;
            end
        end

        % Map local mask → full image coords
        cellMask = false(nr, nc);
        [lr, lc] = find(cellMaskLocal);
        if ~isempty(lr)
            gr = lr + r1 - 1;  gc = lc + c1 - 1;
            ok = gr>=1 & gr<=nr & gc>=1 & gc<=nc;
            cellMask(sub2ind([nr nc], gr(ok), gc(ok))) = true;
        end

        % HARD CAP: clip to a disk of medRadius centred on click.
        % Build cap in local coords (cheap) then map back.
        [lxx,lyy]  = meshgrid(c1:c2, r1:r2);
        capMask    = (lxx-cx).^2 + (lyy-cy).^2 <= medRadius^2;
        cellMaskL2 = false(r2-r1+1, c2-c1+1);
        [lr2,lc2]  = find(cellMask(r1:r2, c1:c2));
        if ~isempty(lr2)
            keep2 = capMask(sub2ind(size(capMask), lr2, lc2));
            cellMaskL2(sub2ind(size(cellMaskL2), lr2(keep2), lc2(keep2))) = true;
        end
        cellMask(r1:r2, c1:c2) = cellMaskL2;

        % Fallback: plain disk of medRadius if nothing survived the cap
        if ~any(cellMask(:))
            [lxx,lyy] = meshgrid(c1:c2, r1:r2);
            capLocal  = (lxx-cx).^2 + (lyy-cy).^2 <= medRadius^2;
            cellMask(r1:r2, c1:c2) = capLocal;
        end

        cellMask(1,:)=false; cellMask(end,:)=false;
        cellMask(:,1)=false; cellMask(:,end)=false;
        if ~any(cellMask(:)), continue; end

        rr = regionprops(cellMask,'Centroid','Area','Perimeter', ...
                                   'Solidity','Eccentricity');
        if isempty(rr), continue; end
        e.Area         = rr(1).Area;
        e.Solidity     = rr(1).Solidity;
        e.Eccentricity = rr(1).Eccentricity;
        e.Centroid     = rr(1).Centroid;
        e.Perimeter    = rr(1).Perimeter;
        e.PixelIdxList = find(cellMask);
        extraStats(end+1) = e; %#ok<AGROW>
    end
end

allKept = [keptStats; extraStats(:)];

if isempty(allKept)
    S.detectMask = true(0,1);
    S.centroids  = zeros(0,2);
    S.deselected = false(0,1);
    S.boundaries = {};
    return;
end

S.detectMask = true(numel(allKept),1);
S.centroids  = reshape([allKept.Centroid],2,[])';
S.deselected = false(numel(allKept),1);
BWk = false(nr,nc);
for i = 1:numel(allKept), BWk(allKept(i).PixelIdxList) = true; end
S.boundaries = bwboundaries(BWk);
end


% =======================================================================
%  GUIDANCE TUNING
% =======================================================================
function p = tuneParamsFromPicks(S, p)
p = sanitizeParams(p);
diagLen = hypot(size(S.I,1),size(S.I,2));
dNear   = max(8, 0.018*diagLen);

if strcmpi(p.channelKind,'trans')
    pp = p;
    pp.sensitivity    = min(0.99, p.baseSensitivity+0.06);
    pp.baseMinArea    = max(1, round(p.baseMinArea*0.85));
    pp.baseMaxArea    = round(p.baseMaxArea*1.15);
    pp.minArea        = pp.baseMinArea; pp.maxArea = pp.baseMaxArea;
    pp.minCircularity = max(0, p.minCircularity-0.10);
    BW  = computeTransBW(S.I, pp);
    CC  = bwconncomp(BW);
    st  = regionprops(CC,'Area','Centroid','Solidity','Perimeter');
    if isempty(st), return; end
    cents = reshape([st.Centroid],2,[])';
    if ~isempty(S.realPts)
        d=safe_pdist2(cents,S.realPts); idx=find(min(d,[],2)<=dNear);
        if ~isempty(idx)
            areas=[st(idx).Area]; sols=[st(idx).Solidity];
            p.baseMinArea     = max(1,round(min(p.baseMinArea, prctile(areas,10)*0.85)));
            p.baseMaxArea     = max(p.baseMinArea+1,round(max(p.baseMaxArea,prctile(areas,90)*1.15)));
            p.baseMinSolidity = max(0,min(p.baseMinSolidity,prctile(sols,20)-0.02));
            p.baseSensitivity = min(0.99,p.baseSensitivity+0.04);
        end
    end
    if ~isempty(S.fakePts)
        d=safe_pdist2(cents,S.fakePts); idx=find(min(d,[],2)<=dNear);
        if ~isempty(idx)
            areasF=[st(idx).Area]; solsF=[st(idx).Solidity];
            p.baseMinArea         = max(p.baseMinArea,round(prctile(areasF,70)*1.05));
            p.baseMinSolidity     = min(1,max(p.baseMinSolidity,prctile(solsF,70)+0.02));
            p.baseSensitivity     = max(0.01,p.baseSensitivity-0.04);
            p.baseMinCircularity  = min(0.90,p.baseMinCircularity+0.05);
        end
    end
else
    % Fluor channel guidance tuning
    pp = p; pp.baseSensitivity=min(0.99,p.baseSensitivity+0.05);
    pp.baseMinSolidity=max(0,p.baseMinSolidity-0.05);
    pp.baseMinArea=max(1,round(p.baseMinArea*0.90));
    pp.baseMaxArea=round(p.baseMaxArea*1.10);
    pp=applyAggressiveness(pp);
    If=imgaussfilt(S.I,pp.gaussSigma);
    if pp.topHatRadius>0
        se=strel('disk',pp.topHatRadius); If=imtophat(If,se);
        lo=prctile(If(:),1); hi=prctile(If(:),99.9);
        If=(If-lo)/max(eps,hi-lo); If=min(max(If,0),1);
    end
    T=adaptthresh(If,pp.sensitivity,'ForegroundPolarity','bright');
    BW=imbinarize(If,T); BW=imfill(BW,'holes');
    BW=bwareaopen(BW,max(1,round(pp.minArea*0.5)));
    CC=bwconncomp(BW);
    st=regionprops(CC,'Area','Solidity','Centroid');
    if isempty(st), return; end
    cents=reshape([st.Centroid],2,[])';
    if ~isempty(S.realPts)
        d=safe_pdist2(cents,S.realPts); idx=find(min(d,[],2)<=dNear);
        if ~isempty(idx)
            areas=[st(idx).Area]; sols=[st(idx).Solidity];
            p.baseMinArea    =max(1,round(min(p.baseMinArea,prctile(areas,10)*0.85)));
            p.baseMaxArea    =max(p.baseMinArea+1,round(max(p.baseMaxArea,prctile(areas,90)*1.15)));
            p.baseMinSolidity=max(0,min(p.baseMinSolidity,prctile(sols,20)-0.02));
            p.baseSensitivity=min(0.99,p.baseSensitivity+0.03);
        end
    end
    if ~isempty(S.fakePts)
        d=safe_pdist2(cents,S.fakePts); idx=find(min(d,[],2)<=dNear);
        if ~isempty(idx)
            areasF=[st(idx).Area]; solsF=[st(idx).Solidity];
            p.baseMinArea    =max(p.baseMinArea,round(prctile(areasF,70)*1.05));
            p.baseMinSolidity=min(1,max(p.baseMinSolidity,prctile(solsF,70)+0.02));
            p.baseSensitivity=max(0.01,p.baseSensitivity-0.03);
        end
    end
end
p = sanitizeParams(p); p = applyAggressiveness(p);
end


% =======================================================================
%  CORE TRANS BINARIZATION
% =======================================================================
function BW = computeTransBW(I, p)
% Step 1–5: illumination-corrected feature map (shared with preview)
feat = computeTransFeature(I, p);

% ---- Step 6: Percentile threshold (sensitivity-driven) ----
%   sensitivity=0.5 → 85th pct  |  1.0 → 70th pct  |  0.0 → 95th pct
pctThresh = 95 - 25*p.sensitivity;
T  = prctile(feat(:), pctThresh);
T  = max(T, 0.01);
BW = feat > T;

% ---- Step 7: Large CLOSING — merges fragmented macrophage interiors ----
closeR   = max(4, round(p.ringRadius * 2.5));
se_close = strel('disk', closeR);
BW = imclose(BW, se_close);

% ---- Step 8: Fill holes ----
if p.fillHoles
    BW = imfill(BW, 'holes');
end

% ---- Step 9: Opening — removes thin debris bridges ----
if p.openRadius > 0
    se_o = strel('disk', p.openRadius);
    BW   = imopen(BW, se_o);
end

% ---- Step 10: Size filter ----
BW = bwareaopen(BW, max(1, p.minArea));
end


% =======================================================================
%  TRANS FEATURE MAP  (shared by BW pipeline + diagnostic preview)
%
%  Returns a [0,1] map where bright pixels = strong "dark-blob" response.
%  Pipeline:
%    1. Percentile normalise
%    2. ILLUMINATION CORRECTION: subtract very-large-Gaussian field
%       (sigma = topHatRadius px).  This flattens the centre-bright vignette
%       so all cells respond equally regardless of their position in the FOV.
%    3. Light Gaussian pre-smooth
%    4. Black top-hat  (imbothat) — localised dark-body response
%    5. LoG at two scales         — dark-blob / halo-ring response
%    6. Combine 50/50, normalise to [0,1]
% =======================================================================
function feat = computeTransFeature(I, p)

% ---- 1. Percentile normalise ----
lo = prctile(I(:),1);  hi = prctile(I(:),99);
In = (I-lo) / max(eps, hi-lo);
In = min(max(In,0),1);

% ---- 2. Illumination / flat-field correction ----
%   A very large Gaussian (sigma = topHatRadius, typically 80–120 px)
%   estimates the slowly-varying illumination field (vignette, uneven
%   lamp, etc.).  Dividing by this field equalises brightness across
%   the image so cells at the bright centre and dark edges are detected
%   with the same sensitivity.
%
%   We use division rather than subtraction so the mean grey level is
%   preserved and the result stays in a sensible range.
illumSigma = max(30, p.topHatRadius);
illumField = imgaussfilt(In, illumSigma);
% Avoid div-by-zero; normalise field so its median = 1 (flat reference)
illumField = illumField / max(eps, median(illumField(:)));
Iflat      = In ./ illumField;
% Re-clip to [0,1] after division
lo2 = prctile(Iflat(:),1); hi2 = prctile(Iflat(:),99);
Iflat = (Iflat-lo2) / max(eps, hi2-lo2);
Iflat = min(max(Iflat,0),1);

% ---- 3. Light Gaussian pre-smooth ----
Ism = imgaussfilt(Iflat, p.gaussSigma);

% ---- 4. Black top-hat (imbothat) — dark cell body response ----
se_body = strel('disk', max(2, p.ringRadius));
darkMap = imbothat(Ism, se_body);

% ---- 5. LoG at two scales — dark-blob / bright-ring response ----
sig1  = max(1,   p.ringRadius / sqrt(2));
sig2  = max(2,   p.ringRadius * 1.4);
h_lap = fspecial('laplacian', 0);
log1  = -imfilter(imgaussfilt(Ism, sig1), h_lap, 'replicate');
log2  = -imfilter(imgaussfilt(Ism, sig2), h_lap, 'replicate');
n1 = prctile(log1(:),99.5); if n1>eps, log1=log1/n1; end
n2 = prctile(log2(:),99.5); if n2>eps, log2=log2/n2; end
logMap = max(max(log1,log2), 0);

% ---- 6. Combine + normalise ----
nd   = prctile(darkMap(:),99.5); if nd>eps, darkMap=darkMap/nd; end
feat = 0.5*darkMap + 0.5*logMap;
feat = min(max(feat,0),1);
end
function h = mkTxt(pnl,str,row,ht,fs,bold)
fw='normal'; if bold, fw='bold'; end
h=uicontrol(pnl,'Style','text','String',str, ...
    'Units','normalized','Position',[0.05 row 0.90 ht], ...
    'FontSize',fs,'FontWeight',fw,'HorizontalAlignment','left', ...
    'BackgroundColor',get(pnl,'BackgroundColor'));
end

function h = mkBtn(pnl,str,pos,fs,cb,varargin)
fw='normal'; if ~isempty(varargin)&&strcmp(varargin{1},'bold'), fw='bold'; end
h = uicontrol(pnl,'Style','pushbutton','String',str, ...
    'Units','normalized','Position',pos, ...
    'FontSize',fs,'FontWeight',fw,'Callback',cb);
end


% =======================================================================
%  IMAGE I/O
% =======================================================================
function I = readToGray(fp, kind)
raw = imread(fp);
if ndims(raw)==3, raw = rgb2gray(raw); end
I = im2single(raw);
switch lower(kind)
    case 'fluor'
        lo = prctile(I(:),0.1); hi = prctile(I(:),99.9);
    otherwise
        lo = prctile(I(:),1);   hi = prctile(I(:),99);
end
I = (I-lo)/max(eps,hi-lo);
I = min(max(I,0),1);
end


% =======================================================================
%  DEFAULTS
% =======================================================================
function params = defaultParams(kind)
switch lower(kind)
    case 'trans'
        params.channelKind        = 'trans';
        params.aggressiveness     = 0.5;
        % topHatRadius: should be > largest cell radius so BG correction
        % doesn't eat the cells themselves.  Macrophages here look ~60-100px
        % across, so use radius 80.
        params.topHatRadius       = 80;
        params.gaussSigma         = 1.5;
        % ringRadius used as closing multiplier (closeR = ringRadius*3).
        % Set to 12 → closing disk of 36px, enough to fill macrophage interior.
        params.ringRadius         = 12;
        params.baseSensitivity    = 0.50;
        params.sensitivity        = 0.50;
        params.openRadius         = 3;
        params.fillHoles          = true;
        params.watershedMinDist   = 12;
        % Area range: macrophages in image appear ~4000–40000 px²
        params.baseMinArea        = 2000;
        params.baseMaxArea        = 60000;
        params.minArea            = 2000;
        params.maxArea            = 60000;
        params.baseMinSolidity    = 0.45;
        params.minSolidity        = 0.45;
        params.minCircularity     = 0.10;
        params.baseMinCircularity = 0.10;
        params.minEcc             = 0.00;
        params.maxEcc             = 0.98;

    case 'fluor'   % AF555 pHrodo channel
        params.channelKind        = 'fluor';
        params.aggressiveness     = 0.5;
        params.gaussSigma         = 1.2;   % legacy UI field, not used for scoring
        params.topHatRadius       = 25;    % legacy UI field, not used for scoring
        params.baseSensitivity    = 0.55;
        params.sensitivity        = 0.55;
        params.baseMinArea        = 100;
        params.baseMaxArea        = 15000;
        params.minArea            = 100;
        params.maxArea            = 15000;
        params.baseMinSolidity    = 0.45;
        params.minSolidity        = 0.45;
        params.minCircularity     = 0.15;
        params.minEcc             = 0.00;
        params.maxEcc             = 0.97;
        params.punctaFractionThreshold = 0.02;  % active if puncta area / cell area > 2%
        params.punctaSmoothSigma       = 0.8;
        params.punctaTopHatRadius      = 5;
        params.punctaCandidateRadius   = 3;
        params.punctaRingInnerRadius   = 5;
        params.punctaRingOuterRadius   = 10;
        params.punctaCandidateMADFactor= 2.0;
        params.punctaMinSpotResponse   = 0.010;
        params.punctaMinRawIntensity   = 0.030;
        params.punctaLocalRatio        = 1.20;
        params.punctaCellRatio         = 1.10;
        params.punctaMaxCV             = 2.50;
        params.punctaSuppressionRadius = 6;
        params.punctaAreaRadius        = 5;
        params.punctaAreaLocalRatio    = 1.10;
        params.punctaAreaMADFactor     = 1.00;
        params.punctaAreaSpotMADFactor = 1.25;
        params.punctaMinArea           = 3;
        params.punctaMaxArea           = 200;
        params.punctaMaxCandidatesPerCell = 250;
        params.punctaRatioEps          = 1e-4;
end
params = sanitizeParams(params, kind);
params = applyAggressiveness(params);
end


% =======================================================================
%  SANITIZE
% =======================================================================
function params = sanitizeParams(p, kind)
if nargin<2, kind='trans'; end
params = p;
if ~isfield(params,'channelKind'), params.channelKind=lower(kind); end

if strcmpi(params.channelKind,'trans')
    defs.aggressiveness     = 0.5;
    defs.topHatRadius       = 80;
    defs.gaussSigma         = 1.5;
    defs.ringRadius         = 12;
    defs.baseSensitivity    = 0.50;
    defs.sensitivity        = 0.50;
    defs.openRadius         = 3;
    defs.fillHoles          = true;
    defs.watershedMinDist   = 12;
    defs.baseMinArea        = 2000;
    defs.baseMaxArea        = 60000;
    defs.minArea            = 2000;
    defs.maxArea            = 60000;
    defs.baseMinSolidity    = 0.45;
    defs.minSolidity        = 0.45;
    defs.minCircularity     = 0.10;
    defs.baseMinCircularity = 0.10;
    defs.minEcc             = 0.00;
    defs.maxEcc             = 0.98;
else
    defs.aggressiveness     = 0.5;
    defs.gaussSigma         = 1.2;
    defs.topHatRadius       = 25;
    defs.baseSensitivity    = 0.55;
    defs.sensitivity        = 0.55;
    defs.baseMinArea        = 100;
    defs.baseMaxArea        = 15000;
    defs.minArea            = 100;
    defs.maxArea            = 15000;
    defs.baseMinSolidity    = 0.45;
    defs.minSolidity        = 0.45;
    defs.minCircularity     = 0.15;
    defs.minEcc             = 0.00;
    defs.maxEcc             = 0.97;
    defs.punctaFractionThreshold = 0.02;
    defs.punctaSmoothSigma       = 0.8;
    defs.punctaTopHatRadius      = 5;
    defs.punctaCandidateRadius   = 3;
    defs.punctaRingInnerRadius   = 5;
    defs.punctaRingOuterRadius   = 10;
    defs.punctaCandidateMADFactor= 2.0;
    defs.punctaMinSpotResponse   = 0.010;
    defs.punctaMinRawIntensity   = 0.030;
    defs.punctaLocalRatio        = 1.20;
    defs.punctaCellRatio         = 1.10;
    defs.punctaMaxCV             = 2.50;
    defs.punctaSuppressionRadius = 6;
    defs.punctaAreaRadius        = 5;
    defs.punctaAreaLocalRatio    = 1.10;
    defs.punctaAreaMADFactor     = 1.00;
    defs.punctaAreaSpotMADFactor = 1.25;
    defs.punctaMinArea           = 3;
    defs.punctaMaxArea           = 200;
    defs.punctaMaxCandidatesPerCell = 250;
    defs.punctaRatioEps          = 1e-4;
end

fds = fieldnames(defs);
for k = 1:numel(fds)
    if ~isfield(params,fds{k}), params.(fds{k})=defs.(fds{k}); end
end

params.aggressiveness  = min(max(params.aggressiveness,0),1);
params.gaussSigma      = max(0.1,params.gaussSigma);
params.topHatRadius    = max(0,round(params.topHatRadius));
params.baseSensitivity = min(max(params.baseSensitivity,0.01),0.99);
params.sensitivity     = min(max(params.sensitivity,0.01),0.99);
params.baseMinArea     = max(1,round(params.baseMinArea));
params.baseMaxArea     = max(params.baseMinArea+1,round(params.baseMaxArea));
params.minArea         = max(1,round(params.minArea));
params.maxArea         = max(params.minArea+1,round(params.maxArea));
params.baseMinSolidity = min(max(params.baseMinSolidity,0),1);
params.minSolidity     = min(max(params.minSolidity,0),1);
params.minCircularity  = min(max(params.minCircularity,0),1);
params.minEcc          = min(max(params.minEcc,0),0.99);
params.maxEcc          = min(max(params.maxEcc,params.minEcc+0.01),0.999);

if strcmpi(params.channelKind,'trans')
    params.ringRadius         = max(1,round(params.ringRadius));
    params.openRadius         = max(0,round(params.openRadius));
    params.watershedMinDist   = max(2,round(params.watershedMinDist));
    params.baseMinCircularity = min(max(params.baseMinCircularity,0),1);
end
if strcmpi(params.channelKind,'fluor')
    params.punctaFractionThreshold = min(max(params.punctaFractionThreshold,0),1);
    params.punctaSmoothSigma       = max(0, params.punctaSmoothSigma);
    params.punctaTopHatRadius      = max(0, round(params.punctaTopHatRadius));
    params.punctaCandidateRadius   = max(1, round(params.punctaCandidateRadius));
    params.punctaRingInnerRadius   = max(params.punctaCandidateRadius+1, round(params.punctaRingInnerRadius));
    params.punctaRingOuterRadius   = max(params.punctaRingInnerRadius+1, round(params.punctaRingOuterRadius));
    params.punctaCandidateMADFactor= max(0, params.punctaCandidateMADFactor);
    params.punctaMinSpotResponse   = max(0, params.punctaMinSpotResponse);
    params.punctaMinRawIntensity   = max(0, params.punctaMinRawIntensity);
    params.punctaLocalRatio        = max(1.0, params.punctaLocalRatio);
    params.punctaCellRatio         = max(0.1, params.punctaCellRatio);
    params.punctaMaxCV             = max(0.1, params.punctaMaxCV);
    params.punctaSuppressionRadius = max(0, round(params.punctaSuppressionRadius));
    params.punctaAreaRadius        = max(params.punctaCandidateRadius, round(params.punctaAreaRadius));
    params.punctaAreaLocalRatio    = max(0.1, params.punctaAreaLocalRatio);
    params.punctaAreaMADFactor     = max(0, params.punctaAreaMADFactor);
    params.punctaAreaSpotMADFactor = max(0, params.punctaAreaSpotMADFactor);
    params.punctaMinArea           = max(1, round(params.punctaMinArea));
    params.punctaMaxArea           = max(params.punctaMinArea, round(params.punctaMaxArea));
    params.punctaMaxCandidatesPerCell = max(1, round(params.punctaMaxCandidatesPerCell));
    params.punctaRatioEps          = max(eps, params.punctaRatioEps);
end
end


% =======================================================================
%  APPLY AGGRESSIVENESS
% =======================================================================
function p = applyAggressiveness(p)
p = sanitizeParams(p);
a = p.aggressiveness; t = (a-0.5)*2;  % -1..+1

if strcmpi(p.channelKind,'trans')
    p.sensitivity  = min(max(p.baseSensitivity - 0.08*t, 0.01), 0.99);
    if t>=0, p.minArea=max(1,round(p.baseMinArea*(1-0.30*t)));
    else,    p.minArea=max(1,round(p.baseMinArea*(1+0.30*(-t)))); end
    p.maxArea        = max(p.minArea+1,round(p.baseMaxArea*(1+0.20*max(t,0))));
    p.minSolidity    = min(max(p.baseMinSolidity-0.15*max(t,0)+0.10*max(-t,0),0),1);
    p.minCircularity = max(0,p.baseMinCircularity-0.15*max(t,0));
else
    % Fluor puncta parameters are intentionally fixed for now. The slider
    % still updates legacy display fields, but object scoring uses the
    % explicit puncta* defaults above until a real parameter UI is added.
    p.sensitivity = min(max(p.baseSensitivity+0.08*t,0.01),0.99);
    if t>=0, p.minArea=max(1,round(p.baseMinArea*(1-0.30*t)));
    else,    p.minArea=max(1,round(p.baseMinArea*(1+0.30*(-t)))); end
    p.maxArea     = max(p.minArea+1,round(p.baseMaxArea*(1+0.15*max(t,0))));
    p.minSolidity = min(max(p.baseMinSolidity-0.15*max(t,0)+0.10*max(-t,0),0),1);
end
end


% =======================================================================
%  STATE INIT
% =======================================================================
function S = initState(I, channelName, params)
S.channelName = channelName;
S.I           = I;
S.params      = params;
S.realPts     = zeros(0,2);
S.fakePts     = zeros(0,2);
S.pickHistory = struct('kind',{},'n',{});
S.detectMask  = false(0,1);
S.centroids   = zeros(0,2);
S.boundaries  = {};
S.deselected  = false(0,1);
S.BW          = [];
S.allStats    = struct([]);  % all morphology-passing candidates (before picks filter)
end

function h = makePickHist(kind,n), h=struct('kind',kind,'n',n); end


% =======================================================================
% =======================================================================
%  RENDER
% =======================================================================
function renderChannel(ax, S)
imshow(S.I,[],'Parent',ax); hold(ax,'on');

% Draw cell boundaries
for k = 1:numel(S.boundaries)
    b = S.boundaries{k}; if isempty(b), continue; end
    isD = (k<=numel(S.deselected)) && S.deselected(k);
    if isD, plot(ax,b(:,2),b(:,1),'r-','LineWidth',1.3);
    else,   plot(ax,b(:,2),b(:,1),'y-','LineWidth',1.3); end
end

% REAL picks: green circle + R label
if ~isempty(S.realPts)
    plot(ax, S.realPts(:,1), S.realPts(:,2), 'o', ...
        'MarkerSize',14, 'Color',[0 0.85 0], 'LineWidth',2);
    for i = 1:size(S.realPts,1)
        text(ax, S.realPts(i,1)+8, S.realPts(i,2), sprintf('R%d',i), ...
            'Color',[0 0.95 0], 'FontSize',7, 'FontWeight','bold');
    end
end

% FAKE picks: red X + F label
if ~isempty(S.fakePts)
    plot(ax, S.fakePts(:,1), S.fakePts(:,2), 'x', ...
        'MarkerSize',14, 'Color',[1 0.2 0.2], 'LineWidth',2);
    for i = 1:size(S.fakePts,1)
        text(ax, S.fakePts(i,1)+8, S.fakePts(i,2), sprintf('F%d',i), ...
            'Color',[1 0.4 0.4], 'FontSize',7, 'FontWeight','bold');
    end
end

if isscalar(S.detectMask)
    nK = double(S.detectMask);
else
    nK = sum(S.detectMask & ~S.deselected);
end
nR = size(S.realPts,1);  nF = size(S.fakePts,1);
pickStr = '';
if nR>0 || nF>0
    pickStr = sprintf('  |  R:%d F:%d → click Update', nR, nF);
end
title(ax, sprintf('%s  |  cells: %d%s', S.channelName, nK, pickStr), ...
    'FontWeight','bold','FontSize',9);
hold(ax,'off');
end


% =======================================================================
%  AF555 TAB RENDER
%  Shows accepted object-level puncta pixels inside TRANS cell masks.
%    green outline = active by puncta fraction
%    white outline = below puncta-fraction cutoff
%    magenta mask  = final accepted puncta area
% =======================================================================
function renderAF555Tab(ax, Strans, Saf555, Iaf555, bgRect)
if nargin < 5, bgRect = []; end
imshow(Iaf555, [], 'Parent', ax); hold(ax,'on');

if ~isempty(bgRect)
    rectangle(ax,'Position',bgRect,'EdgeColor',[0 1 1], ...
        'LineWidth',2,'LineStyle','--');
    bgMeanV = computeBgMean(Iaf555, bgRect);
    text(ax,bgRect(1)+4,bgRect(2)+12, sprintf('BG=%.4f',bgMeanV), ...
        'Color',[0 1 1],'FontSize',7,'FontWeight','bold');
end

finalMask = Strans.detectMask & ~Strans.deselected;
if ~any(finalMask)
    title(ax, 'AF555 puncta — run TRANS Auto-detect first', ...
        'FontWeight','bold');
    hold(ax,'off'); return;
end

puncta = analyzePunctaInTransCells(Strans, Saf555, Iaf555, bgRect);
isAct = puncta.isActive;
nCells = numel(isAct);
nAct = sum(isAct);

if any(puncta.punctaMaskUnion(:))
    mag = cat(3, ones(size(Iaf555)), zeros(size(Iaf555)), ones(size(Iaf555)));
    hP = imshow(mag, 'Parent', ax);
    set(hP, 'AlphaData', 0.70*puncta.punctaMaskUnion);
end

for k = 1:nCells
    b = puncta.cells(k).boundary;
    if isempty(b), continue; end
    if isAct(k)
        plot(ax,b(:,2),b(:,1),'-','Color',[0.1 1 0.2],'LineWidth',2.0);
    else
        plot(ax,b(:,2),b(:,1),'w-','LineWidth',1.0);
    end
end

for i = 1:nCells
    c = puncta.cells(i).centroid;
    if isAct(i)
        labelColor = [1 0.9 0];
        labelWeight = 'bold';
    else
        labelColor = [0.85 0.95 1];
        labelWeight = 'normal';
    end
    text(ax,c(1)+4,c(2),sprintf('%.2f%%',100*puncta.punctaFraction(i)), ...
        'Color',labelColor,'FontSize',6.5,'FontWeight',labelWeight);
end

bgLbl = ''; if puncta.bgMean>0, bgLbl = sprintf('  |  BG=%.4f',puncta.bgMean); end
title(ax, sprintf('AF555 object-level puncta in TRANS masks%s  |  cutoff=%.1f%%  |  Active: %d/%d (%.1f%%)', ...
    bgLbl, 100*puncta.params.punctaFractionThreshold, nAct, nCells, 100*nAct/max(1,nCells)), ...
    'FontWeight','bold','FontSize',8);
hold(ax,'off');
end

function showBWPreview(ax, Strans)
if ~isempty(Strans.BW)
    showBWDirect(ax, Strans.BW, Strans.params);
else
    cla(ax);
    text(0.5,0.5,'Click "Preview B&W mask" or run Auto-detect to see binary image', ...
        'Units','normalized','HorizontalAlignment','center', ...
        'FontSize',12,'Color',[0.4 0.4 0.4],'Parent',ax);
    title(ax,'TRANS B&W Preview','FontWeight','bold');
end
end

function showBWDirect(ax, BW, p)
pctThresh  = 95 - 25*p.sensitivity;
illumSigma = max(30, p.topHatRadius);
closeR     = round(p.ringRadius * 2.5);
title(ax, sprintf(['TRANS B&W  |  illumSig=%d  ringR=%d  closeR=%d  ' ...
    'pctThr=%.0f  minArea=%d'], ...
    illumSigma, p.ringRadius, closeR, pctThresh, p.minArea), ...
    'FontWeight','bold','FontSize',8);
imshow(BW, [], 'Parent', ax);
end


% =======================================================================
%  UTILITIES
% =======================================================================
function pos = centerFig(w,h)
scr = get(0,'ScreenSize');
pos = [max(10,floor((scr(3)-w)/2)) max(40,floor((scr(4)-h)/2)) w h];
end

function roiMask = drawPolyMask(ax, imSize)
roiMask = false(imSize(1),imSize(2));
if exist('drawpolygon','file')==2
    h = drawpolygon(ax,'LineWidth',1.5);
    if isempty(h)||~isvalid(h), return; end
    roiMask = createMask(h,imSize(1),imSize(2)); delete(h);
else
    h = impoly(ax);
    if isempty(h)||~ishandle(h), return; end
    pos = wait(h); if isempty(pos), delete(h); return; end
    roiMask = poly2mask(pos(:,1),pos(:,2),imSize(1),imSize(2)); delete(h);
end
end

function in = pointsInMask(centroids, mask)
if isempty(centroids), in=false(0,1); return; end
x = min(max(round(centroids(:,1)),1),size(mask,2));
y = min(max(round(centroids(:,2)),1),size(mask,1));
in = mask(sub2ind(size(mask),y,x));
end

function out = packageChannel(S)
out.channelName = S.channelName; out.params = S.params;
out.realPts     = S.realPts;     out.fakePts = S.fakePts;
out.deselected  = S.deselected;
out.finalMask   = S.detectMask & ~S.deselected;
out.finalCount  = sum(out.finalMask);
out.centroids   = S.centroids;
end

function r = safeRatio(a,b)
if b<=0, r=NaN; else, r=double(a)/double(b); end
end

function D = safe_pdist2(A,B)
D = sqrt(max(0, sum(A.^2,2)*ones(1,size(B,1)) + ...
              ones(size(A,1),1)*sum(B.^2,2)' - 2*(A*B')));
end
