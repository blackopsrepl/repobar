import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property string configPath: Quickshell.env("REPOBAR_CONFIG") || ((Quickshell.env("HOME") || "") + "/.repobar/config.json")
    property string stateDir: Quickshell.env("REPOBAR_STATE_DIR") || ((Quickshell.env("HOME") || "") + "/.local/state/repobar")
    property string repobarBin: Quickshell.env("REPOBAR_BIN") || "repobar"
    property string snapshotPath: stateDir + "/snapshot.json"
    property string uiPath: stateDir + "/ui.json"
    property string searchPath: stateDir + "/search.json"
    property string stateEventPath: stateDir + "/state-event.json"
    property string textFont: "Fira Code"

    // Omarchy theme wiring: live-follows the active Omarchy theme palette
    // (the same colors.toml the Omarchy shell reads). Falls back to the
    // built-in palette where a key is absent or Omarchy is not running.
    property string themeColorsPath: Quickshell.env("OMARCHY_THEME_COLORS") || ((Quickshell.env("HOME") || "") + "/.local/state/omarchy/current/theme/colors.toml")
    property var themePalette: ({})

    function applyThemeColors(raw) {
        var parsed = {}
        var lines = String(raw || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
            if (match)
                parsed[match[1]] = match[2]
        }
        root.themePalette = parsed
    }

    function themeColor(key, fallback) {
        var value = root.themePalette[key]
        return (typeof value === "string" && value.length > 0) ? value : fallback
    }

    readonly property QtObject theme: QtObject {
        readonly property color bg: root.themeColor("background", "#0B0C16")
        readonly property color bgDeep: root.themeColor("dark_background", "#050711")
        readonly property color surfaceDeep: root.themeColor("selection", "#0F1324")
        readonly property color surfaceAlt: root.themeColor("lighter_background", "#141528")
        readonly property color surfaceHover: root.themeColor("selection", "#18233C")
        readonly property color surfaceSelect: root.themeColor("muted", "#202848")
        readonly property color surfaceDown: root.themeColor("muted", "#223354")
        readonly property color border: root.themeColor("muted", "#253057")
        readonly property color borderStrong: root.themeColor("dark_foreground", "#4A557C")
        readonly property color text: root.themeColor("bright_foreground", "#DDF7FF")
        readonly property color textMuted: root.themeColor("dark_foreground", "#6A6E95")
        readonly property color good: root.themeColor("green", "#82FB9C")
        readonly property color goodSoft: root.themeColor("bright_green", "#9CF7C2")
        readonly property color info: root.themeColor("bright_cyan", "#85E1FB")
        readonly property color accent: root.themeColor("accent", "#8FA4D8")
        readonly property color warn: root.themeColor("yellow", "#F2C572")
        readonly property color bad: root.themeColor("red", "#E06C75")
        readonly property color infoFill: Qt.rgba(root.theme.info.r, root.theme.info.g, root.theme.info.b, 0.16)
        readonly property color goodFill: Qt.rgba(root.theme.goodSoft.r, root.theme.goodSoft.g, root.theme.goodSoft.b, 0.16)
        readonly property color warnFill: Qt.rgba(root.theme.warn.r, root.theme.warn.g, root.theme.warn.b, 0.16)
        readonly property color warnHover: Qt.rgba(root.theme.warn.r, root.theme.warn.g, root.theme.warn.b, 0.08)
    }

    FileView {
        id: themeFile
        path: root.themeColorsPath
        watchChanges: true
        printErrors: false
        onLoaded: root.applyThemeColors(text())
        onFileChanged: reload()
        onLoadFailed: root.applyThemeColors("")
    }

    property var viewData: snapshotAdapter.view && snapshotAdapter.view.summary ? snapshotAdapter.view : ({ summary: {}, chip: {}, repositories: [] })
    property var repositories: viewData.repositories || []
    property var selectedRepository: null
    property bool searchPanelOpen: false
    property string activeSearchQuery: ""
    property var searchData: searchAdapter.status ? ({
        status: searchAdapter.status,
        query: searchAdapter.query,
        selectedFullName: searchAdapter.selectedFullName,
        results: searchAdapter.results || [],
        error: searchAdapter.error
    }) : ({ status: "idle", query: "", selectedFullName: "", results: [], error: "" })
    property var searchResults: searchData.results || []

    // Triage mode: a snapshot-driven cross-repo work queue. All state here is
    // view-local (selection, filter, opened marks); the data itself comes from
    // the cached snapshot projection, so navigation never touches the network.
    property int triageIndex: 0
    property string triageFilter: "all"
    property var triageOpened: ({})

    component RepoActionButton: Button {
        id: actionButton

        property string iconName: "open"
        property string tooltip: ""
        property bool active: false
        property color iconColor: root.theme.text
        property color accentColor: root.theme.info
        property color activeFillColor: root.theme.infoFill
        property color disabledColor: root.theme.borderStrong

        Layout.preferredWidth: 34
        Layout.preferredHeight: 34
        implicitWidth: 34
        implicitHeight: 34
        padding: 0
        hoverEnabled: true

        ToolTip.delay: 350
        ToolTip.visible: actionButton.hovered && actionButton.tooltip.length > 0
        ToolTip.text: actionButton.tooltip
        Accessible.name: actionButton.tooltip
        Accessible.role: Accessible.Button

        background: Rectangle {
            radius: 4
            color: !actionButton.enabled ? root.theme.surfaceDeep : actionButton.down ? root.theme.surfaceDown : actionButton.hovered ? root.theme.surfaceHover : actionButton.active ? actionButton.activeFillColor : root.theme.surfaceDeep
            border.width: 1
            border.color: !actionButton.enabled ? root.theme.border : actionButton.active ? actionButton.accentColor : actionButton.hovered ? root.theme.info : root.theme.border
        }

        contentItem: Item {
            implicitWidth: 34
            implicitHeight: 34

            Canvas {
                id: iconCanvas
                anchors.centerIn: parent
                width: 18
                height: 18

                Connections {
                    target: actionButton
                    function onIconNameChanged() { iconCanvas.requestPaint() }
                    function onActiveChanged() { iconCanvas.requestPaint() }
                    function onEnabledChanged() { iconCanvas.requestPaint() }
                    function onIconColorChanged() { iconCanvas.requestPaint() }
                    function onAccentColorChanged() { iconCanvas.requestPaint() }
                }

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.lineWidth = 1.7
                    ctx.lineCap = "round"
                    ctx.lineJoin = "round"

                    var stroke = actionButton.enabled ? (actionButton.active ? actionButton.accentColor : actionButton.iconColor) : actionButton.disabledColor
                    ctx.strokeStyle = stroke
                    ctx.fillStyle = actionButton.active ? actionButton.accentColor : "transparent"

                    if (actionButton.iconName === "open") {
                        ctx.strokeRect(3.5, 7.5, 7, 7)
                        ctx.beginPath()
                        ctx.moveTo(8.5, 9.5)
                        ctx.lineTo(14.3, 3.7)
                        ctx.moveTo(10.2, 3.7)
                        ctx.lineTo(14.3, 3.7)
                        ctx.lineTo(14.3, 7.8)
                        ctx.stroke()
                    } else if (actionButton.iconName === "read") {
                        ctx.beginPath()
                        ctx.moveTo(5, 3)
                        ctx.lineTo(11.5, 3)
                        ctx.lineTo(14, 5.5)
                        ctx.lineTo(14, 15)
                        ctx.lineTo(5, 15)
                        ctx.closePath()
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.moveTo(11.5, 3)
                        ctx.lineTo(11.5, 5.5)
                        ctx.lineTo(14, 5.5)
                        ctx.moveTo(7, 8)
                        ctx.lineTo(12, 8)
                        ctx.moveTo(7, 11)
                        ctx.lineTo(12, 11)
                        ctx.stroke()
                    } else if (actionButton.iconName === "refresh") {
                        ctx.beginPath()
                        ctx.arc(9, 9, 5.4, 0.45, 4.85, false)
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.moveTo(5.1, 4.8)
                        ctx.lineTo(4.5, 8.1)
                        ctx.lineTo(7.7, 7.2)
                        ctx.moveTo(12.9, 13.2)
                        ctx.lineTo(13.5, 9.9)
                        ctx.lineTo(10.3, 10.8)
                        ctx.stroke()
                    } else if (actionButton.iconName === "pin" || actionButton.iconName === "pinFilled") {
                        ctx.beginPath()
                        ctx.moveTo(6, 3)
                        ctx.lineTo(12.2, 3)
                        ctx.lineTo(11, 6.3)
                        ctx.lineTo(14.5, 9.6)
                        ctx.lineTo(10.4, 9.8)
                        ctx.lineTo(9, 15.2)
                        ctx.lineTo(7.6, 9.8)
                        ctx.lineTo(3.5, 9.6)
                        ctx.lineTo(7, 6.3)
                        ctx.closePath()
                        if (actionButton.active || actionButton.iconName === "pinFilled") {
                            ctx.globalAlpha = actionButton.enabled ? 0.22 : 0.12
                            ctx.fill()
                            ctx.globalAlpha = 1
                        }
                        ctx.stroke()
                    } else if (actionButton.iconName === "hide") {
                        ctx.beginPath()
                        ctx.moveTo(2.5, 9)
                        ctx.bezierCurveTo(5.1, 5.8, 12.9, 5.8, 15.5, 9)
                        ctx.bezierCurveTo(12.9, 12.2, 5.1, 12.2, 2.5, 9)
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.arc(9, 9, 2.1, 0, Math.PI * 2, false)
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.moveTo(4, 14)
                        ctx.lineTo(14, 4)
                        ctx.stroke()
                    }
                }
            }
        }
    }

    component TriageInboxSeparator: Item {
        property string sectionLabel: ""

        implicitWidth: 200
        implicitHeight: 26

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 1
            color: root.theme.border
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            x: 8
            width: separatorLabel.implicitWidth + 12
            height: 16
            radius: 3
            color: root.theme.surfaceDeep

            Text {
                id: separatorLabel
                anchors.centerIn: parent
                text: sectionLabel
                color: root.theme.textMuted
                font.family: root.textFont
                font.pixelSize: 9
                font.bold: true
            }
        }
    }

    component TriageInboxRow: Item {
        id: triageRow

        property var rowData: null
        property int rowIndex: 0
        property bool rowSelected: false
        property bool rowOpened: false

        implicitWidth: 200
        implicitHeight: 44

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 2
            anchors.rightMargin: 2
            radius: 3
            color: triageRow.rowSelected ? root.theme.surfaceSelect : (rowHover.containsMouse ? root.theme.surfaceHover : "transparent")
            border.width: 1
            border.color: triageRow.rowSelected ? root.theme.info : "transparent"
        }

        MouseArea {
            id: rowHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.selectTriageIndex(triageRow.rowIndex)
            onDoubleClicked: root.openTriageItem(triageRow.rowData)
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 8
            spacing: 8

            Rectangle {
                Layout.preferredWidth: 24
                Layout.preferredHeight: 15
                radius: 3
                color: Qt.rgba(triageRow.rowData && triageRow.rowData.kind === "pr" ? root.theme.goodSoft.r : root.theme.info.r, triageRow.rowData && triageRow.rowData.kind === "pr" ? root.theme.goodSoft.g : root.theme.info.g, triageRow.rowData && triageRow.rowData.kind === "pr" ? root.theme.goodSoft.b : root.theme.info.b, 0.16)

                Text {
                    anchors.centerIn: parent
                    text: triageRow.rowData && triageRow.rowData.kind === "pr" ? "PR" : "IS"
                    color: triageRow.rowData && triageRow.rowData.kind === "pr" ? root.theme.goodSoft : root.theme.info
                    font.family: root.textFont
                    font.pixelSize: 8
                    font.bold: true
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Text {
                    Layout.fillWidth: true
                    text: triageRow.rowData ? ("#" + triageRow.rowData.number + " " + (triageRow.rowData.draft ? "[draft] " : "") + triageRow.rowData.title) : ""
                    color: triageRow.rowOpened ? root.theme.textMuted : root.theme.text
                    font.family: root.textFont
                    font.pixelSize: 11
                    font.bold: !triageRow.rowOpened
                    elide: Text.ElideRight
                }

                Text {
                    Layout.fillWidth: true
                    text: triageRow.rowData ? (triageRow.rowData.repoFullName + "  ·  @" + triageRow.rowData.author + "  ·  " + triageRow.rowData.updatedText + (triageRow.rowData.comments > 0 ? "  ·  " + triageRow.rowData.comments + " comments" : "")) : ""
                    color: root.theme.textMuted
                    font.family: root.textFont
                    font.pixelSize: 9
                    elide: Text.ElideRight
                }
            }

            Text {
                visible: triageRow.rowData && triageRow.rowData.labels && triageRow.rowData.labels.length > 0
                text: triageRow.rowData && triageRow.rowData.labels ? "#" + triageRow.rowData.labels.length : ""
                color: root.theme.accent
                font.family: root.textFont
                font.pixelSize: 9
            }

            Text {
                text: triageRow.rowOpened ? "✓" : ""
                color: root.theme.good
                font.family: root.textFont
                font.pixelSize: 10
            }
        }
    }

    component ModeTabButton: Button {
        id: modeTab

        property string label: ""
        property bool selected: false

        implicitWidth: 92
        implicitHeight: 30
        padding: 0
        hoverEnabled: true
        ToolTip.delay: 350
        ToolTip.visible: modeTab.hovered && modeTab.ToolTip.text.length > 0
        Accessible.name: modeTab.label
        Accessible.role: Accessible.Button

        background: Rectangle {
            radius: 4
            color: modeTab.selected ? root.theme.surfaceSelect : modeTab.hovered ? root.theme.surfaceHover : root.theme.surfaceDeep
            border.width: 1
            border.color: modeTab.selected ? root.theme.accent : root.theme.border
        }

        contentItem: Text {
            text: modeTab.label
            color: modeTab.selected ? root.theme.text : root.theme.textMuted
            font.family: root.textFont
            font.pixelSize: 11
            font.bold: modeTab.selected
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    component DragHandle: Item {
        id: handle

        property string tooltip: ""
        property string dragFullName: ""
        property bool active: dragArea.drag.active
        property color iconColor: root.theme.text
        property color accentColor: root.theme.warn

        Layout.preferredWidth: 34
        Layout.preferredHeight: 34
        implicitWidth: 34
        implicitHeight: 34

        ToolTip.delay: 350
        ToolTip.visible: dragArea.containsMouse && handle.tooltip.length > 0
        ToolTip.text: handle.tooltip
        Accessible.name: handle.tooltip
        Accessible.role: Accessible.Button

        Drag.active: dragArea.drag.active
        Drag.keys: ["repobar-pinned-repo"]
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2

        Rectangle {
            anchors.fill: parent
            radius: 4
            color: handle.active ? root.theme.warnFill : dragArea.containsMouse ? root.theme.warnHover : root.theme.surfaceDeep
            border.width: 1
            border.color: handle.active || dragArea.containsMouse ? handle.accentColor : root.theme.border
        }

        Canvas {
            id: dragIcon
            anchors.centerIn: parent
            width: 18
            height: 18

            Connections {
                target: handle
                function onActiveChanged() { dragIcon.requestPaint() }
                function onIconColorChanged() { dragIcon.requestPaint() }
                function onAccentColorChanged() { dragIcon.requestPaint() }
            }

            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                ctx.fillStyle = handle.active ? handle.accentColor : handle.iconColor
                for (var row = 0; row < 3; row++) {
                    for (var column = 0; column < 2; column++) {
                        ctx.beginPath()
                        ctx.arc(6 + column * 6, 5 + row * 4, 1.35, 0, Math.PI * 2)
                        ctx.fill()
                    }
                }
            }
        }

        MouseArea {
            id: dragArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            drag.target: handle
            onPressed: handle.z = 20
            onReleased: {
                handle.x = 0
                handle.y = 0
                handle.z = 0
            }
        }
    }

    function statusColor(status) {
        if (status === "error" || status === "ci-failing") {
            return root.theme.bad
        }
        if (status === "dirty" || status === "work") {
            return root.theme.warn
        }
        if (status === "pending") {
            return root.theme.info
        }
        return root.theme.good
    }

    function runRepobar(args) {
        if (actionRunner.running) {
            actionRunner.signal(9)
            actionRunner.running = false
        }
        actionRunner.command = [root.repobarBin].concat(args).concat(["--config", root.configPath])
        actionRunner.running = true
    }

    function runSearch() {
        var query = repoInput.text.trim()
        if (query.length === 0) {
            root.searchPanelOpen = false
            return
        }
        root.activeSearchQuery = query
        root.searchPanelOpen = true
        runRepobar(["search", query, "--limit", "8"])
    }

    function clearSearchUi() {
        root.searchPanelOpen = false
        root.activeSearchQuery = ""
        repoInput.text = ""
    }

    function searchPanelVisible() {
        return root.searchPanelOpen && searchData.status !== "idle" && searchData.query === root.activeSearchQuery
    }

    function closePanel() {
        runRepobar(["ui", "close"])
    }

    function reloadState() {
        snapshotFile.reload()
        uiFile.reload()
        searchFile.reload()
    }

    function heatmapText(repo) {
        if (repo.pending) {
            return "Refreshing..."
        }
        if (!repo.heatmap) {
            return "Activity heatmap"
        }
        return "Activity " + (repo.heatmap.total || 0) + " commits"
    }

    function heatmapColor(cell) {
        if (!cell) {
            return root.theme.surfaceSelect
        }
        if (cell.empty) {
            return root.theme.bg
        }
        if (cell.intensity >= 4) {
            return root.theme.goodSoft
        }
        if (cell.intensity === 3) {
            return root.theme.good
        }
        if (cell.intensity === 2) {
            return root.theme.good
        }
        if (cell.intensity === 1) {
            return root.theme.border
        }
        return root.theme.surfaceSelect
    }

    function accountHeatmapText() {
        var heatmap = viewData.accountHeatmap
        if (!heatmap || !heatmap.available) {
            return ""
        }
        var provider = root.providerActive("forgejo") ? "Forgejo" : "GitHub"
        return "Global " + provider + " activity  " + (heatmap.total || 0) + " contributions"
    }

    function accountHeatmapWeeks() {
        var heatmap = viewData.accountHeatmap
        if (!heatmap || !heatmap.available || !heatmap.weeks) {
            return []
        }
        return heatmap.weeks
    }

    function accountHeatmapRows() {
        var heatmap = viewData.accountHeatmap
        if (!heatmap || !heatmap.available || !heatmap.rows) {
            return []
        }
        return heatmap.rows
    }

    function accountHeatmapStats() {
        var heatmap = viewData.accountHeatmap
        if (!heatmap || !heatmap.available || !heatmap.stats) {
            return ({})
        }
        return heatmap.stats
    }

    function firstItems(items, limit) {
        var output = []
        if (!items) {
            return output
        }
        for (var index = 0; index < items.length && index < limit; index++) {
            output.push(items[index])
        }
        return output
    }

    function workItems(repo) {
        if (!repo) {
            return 0
        }
        return (repo.issues ? repo.issues.length : 0) + (repo.pulls ? repo.pulls.length : 0)
    }

    function workLabel(repo) {
        if (!repo) {
            return ""
        }
        return (repo.pulls ? repo.pulls.length : 0) + " PR  " + (repo.issues ? repo.issues.length : 0) + " issues"
    }

    function providerActive(provider) {
        return (viewData.summary.provider || "github") === provider
    }

    function repoUrl(repo) {
        return repo.url || ("https://github.com/" + repo.fullName)
    }

    function isPinned(fullName) {
        var normalized = (fullName || "").toString().toLowerCase()
        for (var index = 0; index < root.repositories.length; index++) {
            var repo = root.repositories[index]
            if ((repo.fullName || "").toString().toLowerCase() === normalized && repo.pinned) {
                return true
            }
        }
        return false
    }

    function movePinnedRepo(fullName, position) {
        var normalized = (fullName || "").toString().toLowerCase()
        if (normalized.length === 0) {
            return
        }
        runRepobar(["pin", "move", normalized, position.toString()])
    }

    function searchStatusText() {
        if (searchData.status === "loading") {
            return "Searching " + searchData.query + "..."
        }
        if (searchData.status === "error") {
            return searchData.error || "Search failed"
        }
        if (searchData.status === "ready" && searchResults.length === 0) {
            return "No repositories found for " + searchData.query
        }
        if (searchData.status === "ready") {
            return searchResults.length + " results for " + searchData.query
        }
        return ""
    }

    function triageMode() {
        return uiAdapter.mode === "triage"
    }

    function triageAllItems() {
        var triage = viewData.triage
        return triage && triage.items ? triage.items : []
    }

    function triageTotalsText() {
        var triage = viewData.triage
        if (!triage) {
            return ""
        }
        return triage.pullCount + " PR · " + triage.issueCount + " issues"
    }

    function filteredTriageItems() {
        var items = root.triageAllItems()
        var output = []
        for (var index = 0; index < items.length; index++) {
            if (root.triageFilter === "all" || items[index].kind === root.triageFilter) {
                output.push(items[index])
            }
        }
        return output
    }

    function selectedTriageItem() {
        var items = root.filteredTriageItems()
        return (root.triageIndex >= 0 && root.triageIndex < items.length) ? items[root.triageIndex] : null
    }

    function triageBucketLabel(item) {
        var parsed = Date.parse(item.updatedAt || "")
        if (isNaN(parsed)) {
            return "Earlier"
        }
        var ageDays = (Date.now() - parsed) / 86400000
        if (ageDays < 2) {
            return "Today"
        }
        if (ageDays < 7) {
            return "This week"
        }
        if (ageDays < 30) {
            return "This month"
        }
        return "Older"
    }

    function triageRows() {
        var items = root.filteredTriageItems()
        var rows = []
        var lastBucket = ""
        for (var index = 0; index < items.length; index++) {
            var bucket = root.triageBucketLabel(items[index])
            if (bucket !== lastBucket) {
                rows.push({ isSeparator: true, label: bucket })
                lastBucket = bucket
            }
            rows.push({ isSeparator: false, item: items[index], index: index })
        }
        return rows
    }

    function triageRowForIndex(itemIndex) {
        var rows = root.triageRows()
        for (var index = 0; index < rows.length; index++) {
            if (!rows[index].isSeparator && rows[index].index === itemIndex) {
                return index
            }
        }
        return -1
    }

    function scrollInboxToIndex(itemIndex) {
        var row = root.triageRowForIndex(itemIndex)
        if (row >= 0) {
            inboxList.positionViewAtIndex(row, ListView.Contain)
        }
    }

    function clampTriageIndex() {
        var count = root.filteredTriageItems().length
        if (root.triageIndex >= count) {
            root.triageIndex = Math.max(0, count - 1)
        }
    }

    function moveTriageSelection(delta) {
        var count = root.filteredTriageItems().length
        if (count === 0) {
            return
        }
        var next = Math.max(0, Math.min(count - 1, root.triageIndex + delta))
        if (next === root.triageIndex) {
            return
        }
        root.triageIndex = next
        root.scrollInboxToIndex(next)
    }

    function selectTriageIndex(itemIndex) {
        root.triageIndex = itemIndex
        root.scrollInboxToIndex(itemIndex)
    }

    function setTriageFilter(filter) {
        root.triageFilter = filter
        root.triageIndex = 0
        root.scrollInboxToIndex(0)
    }

    function markTriageOpened(item) {
        if (!item || !item.id) {
            return
        }
        var next = {}
        for (var key in root.triageOpened) {
            next[key] = root.triageOpened[key]
        }
        next[item.id] = true
        root.triageOpened = next
    }

    function openTriageItem(item) {
        if (!item || !(item.url || "").length) {
            return
        }
        root.markTriageOpened(item)
        runRepobar(["open", item.url])
    }

    function showOverviewMode() {
        runRepobar(["ui", "mode", "overview"])
    }

    function showTriageMode() {
        runRepobar(["ui", "mode", "triage"])
    }

    Process {
        id: actionRunner
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim().length) {
                    console.log(text.trim())
                }
            }
        }
    }

    FileView {
        id: stateEventFile
        path: root.stateEventPath
        watchChanges: true
        onFileChanged: root.reloadState()
    }

    FileView {
        id: snapshotFile
        path: root.snapshotPath
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: snapshotAdapter
            property string generatedAt: ""
            property var account: ({})
            property var repositories: []
            property var localRepositories: []
            property var view: ({})
        }
    }

    FileView {
        id: uiFile
        path: root.uiPath
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: uiAdapter
            property bool open: false
            property string mode: "overview"
            property string focusRepository: ""
            property string requestedAt: ""
        }
    }

    FileView {
        id: searchFile
        path: root.searchPath
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: searchAdapter
            property string status: "idle"
            property string query: ""
            property string requestId: ""
            property string selectedFullName: ""
            property var results: []
            property string error: ""
            property string updatedAt: ""
        }
    }

    Component.onCompleted: root.reloadState()

    PanelWindow {
        id: panel
        visible: uiAdapter.open
        screen: Quickshell.screens.length ? Quickshell.screens[0] : null
        property int verticalMargin: 18
        implicitWidth: screen ? screen.width : 960
        implicitHeight: screen ? screen.height : 760
        color: "transparent"
        focusable: true
        aboveWindows: true
        exclusionMode: ExclusionMode.Ignore
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        margins {
            top: 0
            bottom: 0
            left: 0
            right: 0
        }
        onVisibleChanged: {
            if (visible) {
                root.searchPanelOpen = false
                root.activeSearchQuery = ""
                repoInput.forceActiveFocus()
            }
        }

        Shortcut {
            sequence: "Esc"
            context: Qt.WindowShortcut
            onActivated: root.closePanel()
        }

        Shortcut {
            sequence: "j"
            context: Qt.WindowShortcut
            enabled: root.triageMode()
            onActivated: root.moveTriageSelection(1)
        }
        Shortcut {
            sequence: "k"
            context: Qt.WindowShortcut
            enabled: root.triageMode()
            onActivated: root.moveTriageSelection(-1)
        }
        Shortcut {
            sequence: "o"
            context: Qt.WindowShortcut
            enabled: root.triageMode() && root.selectedTriageItem() !== null
            onActivated: root.openTriageItem(root.selectedTriageItem())
        }
        Shortcut {
            sequence: "r"
            context: Qt.WindowShortcut
            enabled: root.triageMode()
            onActivated: runRepobar(["refresh"])
        }

        Item {
            anchors.fill: parent

            Rectangle {
                anchors.fill: parent
                color: root.theme.bgDeep
                opacity: 0.66
            }

            Rectangle {
                id: modalFrame
                anchors.centerIn: parent
                width: Math.min(960, Math.max(320, panel.width - 36))
                height: Math.min(panel.height - 16, Math.max(420, panel.height - (panel.verticalMargin * 2)))
                color: root.theme.bg
                border.color: root.theme.good
                border.width: 1
                radius: 4
                focus: true
                Keys.onEscapePressed: root.closePanel()

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text {
                                text: "RepoBar"
                                color: root.theme.text
                                font.family: root.textFont
                                font.pixelSize: 22
                                font.bold: true
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "@" + (viewData.summary.account || "not authenticated") + "  " + (viewData.summary.repoCount || 0) + " repos  " + (viewData.summary.openPulls || 0) + " PR  " + (viewData.summary.openIssues || 0) + " issues"
                                color: root.theme.goodSoft
                                font.family: root.textFont
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                        }

                        ModeTabButton {
                            label: "Overview"
                            selected: !root.triageMode()
                            enabled: root.triageMode()
                            ToolTip.text: "Repository cards"
                            onClicked: root.showOverviewMode()
                        }
                        ModeTabButton {
                            label: "Triage"
                            selected: root.triageMode()
                            enabled: !root.triageMode()
                            ToolTip.text: "Cross-repo issue and PR inbox"
                            onClicked: root.showTriageMode()
                        }
                        Button {
                            text: "GH"
                            enabled: !root.providerActive("github")
                            onClicked: runRepobar(["provider", "github"])
                        }
                        Button {
                            text: "FJ"
                            enabled: !root.providerActive("forgejo")
                            onClicked: runRepobar(["provider", "forgejo"])
                        }
                        Button {
                            text: "Refresh"
                            onClicked: runRepobar(["refresh"])
                        }
                        Button {
                            text: "Close"
                            onClicked: root.closePanel()
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 104
                        visible: !!(viewData.accountHeatmap && viewData.accountHeatmap.available) && !root.triageMode()
                        color: root.theme.surfaceDeep
                        border.color: root.theme.border
                        border.width: 1
                        radius: 4

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 10

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 6

                                Text {
                                    text: root.accountHeatmapText()
                                    color: root.theme.goodSoft
                                    font.family: root.textFont
                                    font.pixelSize: 11
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }

                                Flickable {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 74
                                    contentWidth: accountHeatmapGrid.implicitWidth
                                    contentHeight: accountHeatmapGrid.implicitHeight
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds

                                    Column {
                                        id: accountHeatmapGrid
                                        spacing: 2

                                        Repeater {
                                            model: root.accountHeatmapRows()

                                            Row {
                                                property var rowData: modelData
                                                spacing: 2

                                                Repeater {
                                                    model: rowData.cells || []

                                                    Rectangle {
                                                        width: 8
                                                        height: 8
                                                        radius: 1
                                                        color: root.heatmapColor(modelData)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                Layout.preferredWidth: 220
                                Layout.fillHeight: true
                                visible: modalFrame.width >= 760
                                color: root.theme.bg
                                border.color: root.theme.border
                                border.width: 1
                                radius: 3

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 4

                                    Text {
                                        Layout.fillWidth: true
                                        text: "Contribution summary"
                                        color: root.theme.info
                                        font.family: root.textFont
                                        font.pixelSize: 10
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }

                                    GridLayout {
                                        Layout.fillWidth: true
                                        columns: 2
                                        rowSpacing: 2
                                        columnSpacing: 8

                                        Text {
                                            text: "Active"
                                            color: root.theme.textMuted
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: (root.accountHeatmapStats().activeDays || 0) + " days"
                                            color: root.theme.text
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            text: "Streak"
                                            color: root.theme.textMuted
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: (root.accountHeatmapStats().currentStreak || 0) + " days"
                                            color: root.theme.text
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            text: "Best day"
                                            color: root.theme.textMuted
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: root.accountHeatmapStats().bestDayText || "none"
                                            color: root.theme.text
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            text: "Peak"
                                            color: root.theme.textMuted
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: (root.accountHeatmapStats().bestCount || 0) + " contributions"
                                            color: root.theme.text
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        visible: !root.triageMode()
                        spacing: 8

                        TextField {
                            id: repoInput
                            Layout.fillWidth: true
                            Layout.maximumWidth: 360
                            placeholderText: "owner/name or search"
                            font.family: root.textFont
                            onAccepted: root.runSearch()
                            onTextChanged: {
                                if (repoInput.text.trim().length === 0 || (root.activeSearchQuery.length > 0 && repoInput.text.trim() !== root.activeSearchQuery)) {
                                    root.searchPanelOpen = false
                                }
                            }
                            Keys.onEscapePressed: {
                                if (root.searchPanelOpen) {
                                    root.clearSearchUi()
                                } else {
                                    root.closePanel()
                                }
                            }
                        }
                        Button {
                            text: "Search"
                            onClicked: root.runSearch()
                        }
                        Item {
                            Layout.fillWidth: true
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: root.theme.border
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    visible: root.searchPanelVisible() && !root.triageMode()
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Text {
                            Layout.fillWidth: true
                            text: root.searchStatusText()
                            color: searchData.status === "error" ? root.theme.bad : root.theme.goodSoft
                            font.family: root.textFont
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }

                        Button {
                            Layout.preferredHeight: 26
                            Layout.preferredWidth: 64
                            text: "Clear"
                            onClicked: root.clearSearchUi()
                        }
                    }

                    Repeater {
                        model: root.searchResults.slice(0, 6)

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 74
                            color: searchData.selectedFullName === modelData.fullName.toString().toLowerCase() ? root.theme.surfaceSelect : root.theme.surfaceAlt
                            border.color: searchData.selectedFullName === modelData.fullName.toString().toLowerCase() ? root.theme.info : root.theme.border
                            border.width: 1
                            radius: 4

                            MouseArea {
                                anchors.fill: parent
                                onClicked: root.runRepobar(["search", "select", modelData.fullName])
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 8
                                spacing: 10

                                Rectangle {
                                    Layout.preferredWidth: 34
                                    Layout.preferredHeight: 34
                                    radius: 4
                                    color: root.theme.bg
                                    border.color: root.theme.border
                                    border.width: 1
                                    clip: true

                                    Image {
                                        anchors.fill: parent
                                        anchors.margins: 1
                                        source: modelData.ownerAvatarUrl || ""
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        visible: source.toString().length > 0
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        text: (modelData.owner || "?").toString().slice(0, 1).toUpperCase()
                                        color: root.theme.goodSoft
                                        font.family: root.textFont
                                        font.pixelSize: 13
                                        font.bold: true
                                        visible: !(modelData.ownerAvatarUrl || "")
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.fullName || ""
                                        color: root.theme.text
                                        font.family: root.textFont
                                        font.pixelSize: 13
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.description || "No description"
                                        color: root.theme.accent
                                        font.family: root.textFont
                                        font.pixelSize: 10
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: "Stars " + ((modelData.stats && modelData.stats.stars) || 0)
                                        color: root.theme.textMuted
                                        font.family: root.textFont
                                        font.pixelSize: 10
                                        elide: Text.ElideRight
                                    }
                                }

                                RowLayout {
                                    Layout.preferredWidth: implicitWidth
                                    spacing: 6

                                    RepoActionButton {
                                        iconName: "open"
                                        tooltip: "Open repository"
                                        accentColor: root.theme.info
                                        onClicked: {
                                            root.runRepobar(["open", root.repoUrl(modelData)])
                                            root.clearSearchUi()
                                        }
                                    }
                                    RepoActionButton {
                                        iconName: root.isPinned(modelData.fullName) ? "pinFilled" : "pin"
                                        tooltip: root.isPinned(modelData.fullName) ? "Already pinned" : "Pin repository"
                                        active: root.isPinned(modelData.fullName)
                                        enabled: !root.isPinned(modelData.fullName)
                                        accentColor: root.theme.goodSoft
                                        activeFillColor: root.theme.goodFill
                                        onClicked: {
                                            root.runRepobar(["pin", modelData.fullName])
                                            root.clearSearchUi()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 220
                    visible: !root.triageMode() && root.selectedRepository !== null
                    color: root.theme.surfaceDeep
                    border.color: root.theme.border
                    border.width: 1
                    radius: 4

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                Layout.fillWidth: true
                                text: root.selectedRepository ? (root.selectedRepository.fullName + "  " + root.workLabel(root.selectedRepository)) : ""
                                color: root.theme.text
                                font.family: root.textFont
                                font.pixelSize: 13
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            Button {
                                Layout.preferredHeight: 28
                                Layout.preferredWidth: 72
                                text: "Open"
                                enabled: root.selectedRepository !== null
                                onClicked: root.runRepobar(["open", root.repoUrl(root.selectedRepository)])
                            }
                            Button {
                                Layout.preferredHeight: 28
                                Layout.preferredWidth: 72
                                text: "Close"
                                onClicked: root.selectedRepository = null
                            }
                        }

                        Flickable {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            contentWidth: width
                            contentHeight: readerColumn.implicitHeight
                            clip: true

                            ColumnLayout {
                                id: readerColumn
                                width: parent.width
                                spacing: 8

                                Text {
                                    Layout.fillWidth: true
                                    visible: root.selectedRepository !== null && root.workItems(root.selectedRepository) === 0
                                    text: "No open issues or pull requests in the cached snapshot."
                                    color: root.theme.textMuted
                                    font.family: root.textFont
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                }

                                Text {
                                    Layout.fillWidth: true
                                    visible: root.selectedRepository && root.selectedRepository.pulls && root.selectedRepository.pulls.length > 0
                                    text: "Pull requests"
                                    color: root.theme.info
                                    font.family: root.textFont
                                    font.pixelSize: 11
                                    font.bold: true
                                }

                                Repeater {
                                    model: (root.selectedRepository && root.selectedRepository.pulls) ? root.firstItems(root.selectedRepository.pulls, 3) : []

                                    ColumnLayout {
                                        width: readerColumn.width
                                        spacing: 3

                                        RowLayout {
                                            width: parent.width
                                            spacing: 8

                                            Text {
                                                Layout.fillWidth: true
                                                text: "#" + modelData.number + " " + (modelData.draft ? "[draft] " : "") + modelData.title
                                                color: root.theme.text
                                                font.family: root.textFont
                                                font.pixelSize: 12
                                                font.bold: true
                                                elide: Text.ElideRight
                                            }

                                            Text {
                                                text: "@" + modelData.author + "  " + modelData.updatedText
                                                color: root.theme.textMuted
                                                font.family: root.textFont
                                                font.pixelSize: 10
                                                Layout.preferredWidth: 150
                                                elide: Text.ElideRight
                                            }

                                            Button {
                                                Layout.preferredHeight: 24
                                                Layout.preferredWidth: 56
                                                text: "Open"
                                                enabled: (modelData.url || "").length > 0
                                                onClicked: root.runRepobar(["open", modelData.url])
                                            }
                                        }

                                        Text {
                                            width: parent.width
                                            text: modelData.body || "No description."
                                            color: root.theme.accent
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                            wrapMode: Text.Wrap
                                            maximumLineCount: 2
                                            elide: Text.ElideRight
                                        }

                                        Rectangle {
                                            width: parent.width
                                            height: 1
                                            color: root.theme.border
                                        }
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    visible: root.selectedRepository && root.selectedRepository.issues && root.selectedRepository.issues.length > 0
                                    text: "Issues"
                                    color: root.theme.info
                                    font.family: root.textFont
                                    font.pixelSize: 11
                                    font.bold: true
                                }

                                Repeater {
                                    model: (root.selectedRepository && root.selectedRepository.issues) ? root.firstItems(root.selectedRepository.issues, 3) : []

                                    ColumnLayout {
                                        width: readerColumn.width
                                        spacing: 3

                                        RowLayout {
                                            width: parent.width
                                            spacing: 8

                                            Text {
                                                Layout.fillWidth: true
                                                text: "#" + modelData.number + " " + modelData.title
                                                color: root.theme.text
                                                font.family: root.textFont
                                                font.pixelSize: 12
                                                font.bold: true
                                                elide: Text.ElideRight
                                            }

                                            Text {
                                                text: "@" + modelData.author + "  " + modelData.updatedText
                                                color: root.theme.textMuted
                                                font.family: root.textFont
                                                font.pixelSize: 10
                                                Layout.preferredWidth: 150
                                                elide: Text.ElideRight
                                            }

                                            Button {
                                                Layout.preferredHeight: 24
                                                Layout.preferredWidth: 56
                                                text: "Open"
                                                enabled: (modelData.url || "").length > 0
                                                onClicked: root.runRepobar(["open", modelData.url])
                                            }
                                        }

                                        Text {
                                            width: parent.width
                                            text: modelData.body || "No description."
                                            color: root.theme.accent
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                            wrapMode: Text.Wrap
                                            maximumLineCount: 2
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            width: parent.width
                                            visible: modelData.labels && modelData.labels.length > 0
                                            text: "Labels: " + modelData.labels.join(", ")
                                            color: root.theme.textMuted
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                            elide: Text.ElideRight
                                        }

                                        Rectangle {
                                            width: parent.width
                                            height: 1
                                            color: root.theme.border
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    id: triageSplit
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: root.triageMode()
                    color: root.theme.surfaceDeep
                    border.color: root.theme.border
                    border.width: 1
                    radius: 4

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 1
                        spacing: 0

                        // Inbox: every open PR and issue across the cached
                        // snapshot, newest first, grouped by age.
                        ColumnLayout {
                            id: inboxCol
                            Layout.preferredWidth: Math.min(400, triageSplit.width * 0.46)
                            Layout.maximumWidth: Math.min(400, Math.max(240, triageSplit.width * 0.5))
                            Layout.fillWidth: false
                            Layout.fillHeight: true
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.margins: 8
                                spacing: 6

                                Text {
                                    text: "Inbox"
                                    color: root.theme.text
                                    font.family: root.textFont
                                    font.pixelSize: 12
                                    font.bold: true
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: root.triageTotalsText()
                                    color: root.theme.textMuted
                                    font.family: root.textFont
                                    font.pixelSize: 10
                                    elide: Text.ElideRight
                                }

                                Button {
                                    checkable: true
                                    checked: root.triageFilter === "all"
                                    enabled: root.triageFilter !== "all"
                                    text: "All"
                                    onClicked: root.setTriageFilter("all")
                                }
                                Button {
                                    checkable: true
                                    checked: root.triageFilter === "pr"
                                    enabled: root.triageFilter !== "pr"
                                    text: "PR"
                                    onClicked: root.setTriageFilter("pr")
                                }
                                Button {
                                    checkable: true
                                    checked: root.triageFilter === "issue"
                                    enabled: root.triageFilter !== "issue"
                                    text: "Issues"
                                    onClicked: root.setTriageFilter("issue")
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: root.theme.border
                            }

                            ListView {
                                id: inboxList
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                spacing: 0
                                model: root.triageRows()
                                currentIndex: -1
                                cacheBuffer: 600

                                delegate: Item {
                                    width: inboxList.width
                                    height: modelData.isSeparator ? 26 : 44

                                    TriageInboxSeparator {
                                        anchors.fill: parent
                                        visible: modelData.isSeparator
                                        sectionLabel: modelData.label || ""
                                    }

                                    TriageInboxRow {
                                        anchors.fill: parent
                                        visible: !modelData.isSeparator
                                        rowData: modelData.item || null
                                        rowIndex: modelData.index || 0
                                        rowSelected: modelData.index === root.triageIndex
                                        rowOpened: !!(root.triageOpened[modelData.item ? modelData.item.id : ""])
                                    }
                                }
                            }

                            Text {
                                Layout.margins: 6
                                Layout.fillWidth: true
                                visible: root.triageRows().length === 0
                                text: root.triageAllItems().length === 0 ? "No open pull requests or issues in the cached snapshot." : "No items match this filter."
                                color: root.theme.textMuted
                                font.family: root.textFont
                                font.pixelSize: 11
                                wrapMode: Text.Wrap
                            }
                        }

                        Rectangle {
                            Layout.preferredWidth: 1
                            Layout.fillHeight: true
                            color: root.theme.border
                        }

                        // Reader: the selected item, full body, no fetches.
                        ColumnLayout {
                            id: readerCol
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumWidth: 300
                            Layout.preferredWidth: Math.max(300, triageSplit.width - Math.min(400, triageSplit.width * 0.46) - 1)
                            spacing: 8

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                ColumnLayout {
                                    id: readerEmpty
                                    anchors.centerIn: parent
                                    visible: root.selectedTriageItem() === null
                                    spacing: 4

                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: "Nothing selected"
                                        color: root.theme.textMuted
                                        font.family: root.textFont
                                        font.pixelSize: 12
                                        font.bold: true
                                    }
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: "Pick an item from the inbox  ·  j / k to move  ·  Enter to open"
                                        color: root.theme.borderStrong
                                        font.family: root.textFont
                                        font.pixelSize: 10
                                    }
                                }

                                Flickable {
                                    id: triageReaderScroll
                                    anchors.fill: parent
                                    contentWidth: width
                                    contentHeight: triageReaderColumn.implicitHeight + 16
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds
                                    visible: root.selectedTriageItem() !== null

                                    ScrollBar.vertical: ScrollBar {
                                        policy: triageReaderScroll.contentHeight > triageReaderScroll.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                                    }

                                    ColumnLayout {
                                        id: triageReaderColumn
                                        width: triageReaderScroll.width
                                        spacing: 8

                                        RowLayout {
                                            Layout.fillWidth: true
                                            Layout.margins: 10
                                            spacing: 8

                                            Rectangle {
                                                Layout.preferredWidth: 4
                                                Layout.fillHeight: true
                                                Layout.alignment: Qt.AlignTop
                                                radius: 2
                                                color: root.selectedTriageItem() && root.selectedTriageItem().kind === "pr" ? root.theme.goodSoft : root.theme.info
                                            }

                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 3

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: root.selectedTriageItem() ? (root.selectedTriageItem().kind === "pr" ? "Pull Request" : "Issue") : ""
                                                    color: root.selectedTriageItem() && root.selectedTriageItem().kind === "pr" ? root.theme.goodSoft : root.theme.info
                                                    font.family: root.textFont
                                                    font.pixelSize: 9
                                                    font.bold: true
                                                }

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: root.selectedTriageItem() ? ("#" + root.selectedTriageItem().number + " " + root.selectedTriageItem().title) : ""
                                                    color: root.theme.text
                                                    font.family: root.textFont
                                                    font.pixelSize: 14
                                                    font.bold: true
                                                    wrapMode: Text.Wrap
                                                }

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: root.selectedTriageItem() ? (root.selectedTriageItem().repoFullName + "  ·  opened by @" + root.selectedTriageItem().author + "  ·  updated " + root.selectedTriageItem().updatedText + (root.selectedTriageItem().draft ? "  ·  draft" : "")) : ""
                                                    color: root.theme.textMuted
                                                    font.family: root.textFont
                                                    font.pixelSize: 10
                                                    elide: Text.ElideRight
                                                }

                                                Text {
                                                    Layout.fillWidth: true
                                                    visible: root.selectedTriageItem() && root.selectedTriageItem().labels && root.selectedTriageItem().labels.length > 0
                                                    text: root.selectedTriageItem() ? root.selectedTriageItem().labels.join("  ") : ""
                                                    color: root.theme.accent
                                                    font.family: root.textFont
                                                    font.pixelSize: 10
                                                    wrapMode: Text.Wrap
                                                }
                                            }

                                            Text {
                                                text: root.selectedTriageItem() ? ((root.selectedTriageItem().comments + root.selectedTriageItem().reviewComments) + " ✎") : ""
                                                visible: root.selectedTriageItem() && (root.selectedTriageItem().comments + root.selectedTriageItem().reviewComments) > 0
                                                color: root.theme.textMuted
                                                font.family: root.textFont
                                                font.pixelSize: 10
                                            }
                                        }

                                        Rectangle {
                                            Layout.fillWidth: true
                                            Layout.leftMargin: 10
                                            Layout.rightMargin: 10
                                            height: 1
                                            color: root.theme.border
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            Layout.leftMargin: 10
                                            Layout.rightMargin: 10
                                            text: root.selectedTriageItem() ? (root.selectedTriageItem().bodyFull || "No description.") : ""
                                            color: root.theme.accent
                                            font.family: root.textFont
                                            font.pixelSize: 11
                                            wrapMode: Text.Wrap
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            Layout.margins: 10
                                            spacing: 8

                                            Button {
                                                text: "Open in browser"
                                                enabled: root.selectedTriageItem() !== null
                                                onClicked: root.openTriageItem(root.selectedTriageItem())
                                            }
                                            Text {
                                                text: "Esc closes the panel  ·  o opens the selected item"
                                                color: root.theme.borderStrong
                                                font.family: root.textFont
                                                font.pixelSize: 9
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                ListView {
                    id: repoList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 8
                    visible: !root.triageMode()
                    model: repositories

                    MouseArea {
                        property int wheelFlickSpeed: 5
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        scrollGestureEnabled: false
                        onWheel: function(event) {
                            var velocity = event.angleDelta.y * wheelFlickSpeed
                            if (repoList.verticalOvershoot !== 0 ||
                                    (velocity > 0 && repoList.verticalVelocity <= 0) ||
                                    (velocity < 0 && repoList.verticalVelocity >= 0)) {
                                repoList.flick(0, velocity - repoList.verticalVelocity)
                            } else {
                                repoList.cancelFlick()
                            }
                            event.accepted = true
                        }
                    }

                    delegate: Rectangle {
                                id: repoCard

                                property bool dropTarget: false
                                property string dragFullName: (modelData.fullName || "").toString().toLowerCase()
                                property int repoIndex: index

                                width: repoList.width
                                height: 196
                                color: dropTarget ? root.theme.warnFill : root.theme.surfaceAlt
                                border.color: dropTarget ? root.theme.warn : statusColor(modelData.status)
                                border.width: 1
                                radius: 4

                                DropArea {
                                    anchors.fill: parent
                                    enabled: modelData.pinned
                                    keys: ["repobar-pinned-repo"]
                                    onEntered: function(drag) {
                                        if (drag.source && drag.source.dragFullName !== repoCard.dragFullName) {
                                            repoCard.dropTarget = true
                                        }
                                    }
                                    onExited: repoCard.dropTarget = false
                                    onDropped: function(drop) {
                                        repoCard.dropTarget = false
                                        if (drop.source && drop.source.dragFullName !== repoCard.dragFullName) {
                                            root.movePinnedRepo(drop.source.dragFullName, repoCard.repoIndex)
                                        }
                                    }
                                }

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 10
                                    spacing: 8

                                    RowLayout {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        spacing: 12

                                        Rectangle {
                                            width: 8
                                            Layout.fillHeight: true
                                            radius: 2
                                            color: statusColor(modelData.status)
                                        }

                                        Rectangle {
                                            Layout.preferredWidth: 42
                                            Layout.preferredHeight: 42
                                            radius: 4
                                            color: root.theme.bg
                                            border.color: root.theme.border
                                            border.width: 1
                                            clip: true

                                            Image {
                                                anchors.fill: parent
                                                anchors.margins: 1
                                                source: modelData.ownerAvatarUrl || ""
                                                fillMode: Image.PreserveAspectCrop
                                                asynchronous: true
                                                visible: source.toString().length > 0
                                            }

                                            Text {
                                                anchors.centerIn: parent
                                                text: (modelData.owner || "?").toString().slice(0, 1).toUpperCase()
                                                color: root.theme.goodSoft
                                                font.family: root.textFont
                                                font.pixelSize: 16
                                                font.bold: true
                                                visible: !(modelData.ownerAvatarUrl || "")
                                            }
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 4
                                            Text {
                                                text: modelData.fullName || ""
                                                color: root.theme.text
                                                font.family: root.textFont
                                                font.pixelSize: 16
                                                font.bold: true
                                            }
                                            Text {
                                                text: modelData.pending ? "Pending refresh" : (modelData.description || "")
                                                color: modelData.pending ? root.theme.info : root.theme.accent
                                                font.family: root.textFont
                                                font.pixelSize: 11
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                            Text {
                                                text: "CI " + (modelData.ciStatus || "unknown") + "  PR " + (modelData.openPulls || 0) + "  Issues " + (modelData.openIssues || 0) + "  Stars " + (modelData.stars || 0) + "  Updated " + (modelData.pushedText || "unknown")
                                                color: root.theme.goodSoft
                                                font.family: root.textFont
                                                font.pixelSize: 12
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                            Text {
                                                text: modelData.local ? ("Local " + modelData.local.branch + "  ahead " + modelData.local.ahead + " behind " + modelData.local.behind + " dirty " + modelData.local.dirtyCount) : "No matched local checkout"
                                                color: modelData.local && modelData.local.dirty ? root.theme.warn : root.theme.textMuted
                                                font.family: root.textFont
                                                font.pixelSize: 11
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                            Text {
                                                text: (modelData.latestRelease ? ("Release " + modelData.latestRelease.tag + "  ") : "") + (modelData.latestActivity ? modelData.latestActivity.title : "No recent activity")
                                                color: root.theme.info
                                                font.family: root.textFont
                                                font.pixelSize: 11
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                        }
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 38
                                        spacing: 8

                                        Text {
                                            text: heatmapText(modelData)
                                            color: root.theme.textMuted
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                            Layout.preferredWidth: modalFrame.width < 560 ? 108 : 136
                                            Layout.maximumWidth: 150
                                            elide: Text.ElideRight
                                        }

                                        Item {
                                            id: heatmapTrack
                                            Layout.fillWidth: true
                                            Layout.minimumWidth: 58
                                            Layout.preferredHeight: 18
                                            clip: true

                                            Row {
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 2
                                                Repeater {
                                                    model: modelData.heatmap && modelData.heatmap.cells ? modelData.heatmap.cells : []
                                                    Rectangle {
                                                        width: 6
                                                        height: 14
                                                        radius: 1
                                                        color: root.heatmapColor(modelData)
                                                    }
                                                }
                                            }
                                        }

                                        RowLayout {
                                            id: repoActionStrip
                                            Layout.preferredWidth: implicitWidth
                                            spacing: 2

                                            DragHandle {
                                                visible: modelData.pinned
                                                tooltip: "Drag pinned repository"
                                                dragFullName: repoCard.dragFullName
                                            }

                                            RepoActionButton {
                                                iconName: "open"
                                                tooltip: "Open repository"
                                                accentColor: root.theme.info
                                                onClicked: runRepobar(["open", root.repoUrl(modelData)])
                                            }

                                            RepoActionButton {
                                                iconName: "read"
                                                tooltip: "Read work items"
                                                enabled: root.workItems(modelData) > 0
                                                accentColor: root.theme.goodSoft
                                                onClicked: root.selectedRepository = modelData
                                            }

                                            RepoActionButton {
                                                iconName: "refresh"
                                                tooltip: "Refresh repositories"
                                                accentColor: root.theme.info
                                                onClicked: runRepobar(["refresh"])
                                            }

                                            RepoActionButton {
                                                iconName: modelData.pinned ? "pinFilled" : "pin"
                                                tooltip: modelData.pinned ? "Unpin repository" : "Pin repository"
                                                active: modelData.pinned
                                                accentColor: root.theme.goodSoft
                                                activeFillColor: root.theme.goodFill
                                                onClicked: runRepobar([modelData.pinned ? "unpin" : "pin", modelData.fullName])
                                            }

                                            RepoActionButton {
                                                iconName: "hide"
                                                tooltip: "Hide repository"
                                                accentColor: root.theme.bad
                                                onClicked: runRepobar(["hide", modelData.fullName])
                                            }
                                        }
                                    }
                                }
                    }
                }
            }
        }
        }
    }
}
