import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "lib/Model.js" as Model

// Bar icon and panel. All state that outlives the panel (the listener list,
// alerts, actions) lives in Service.qml; this file is view and keyboard only.
Panel {
  id: root
  moduleName: "io.github.saikomantisu.portside"
  // The service owns the "portside" IPC target.
  manageIpc: false

  property var service: null
  readonly property var rowsAll: service ? service.visibleRows : []
  readonly property var sum: Model.summary(rowsAll)

  property string filter: "dev"
  property string query: ""
  property var selected: ({})
  property var collapsed: ({ apps: true, system: true })
  property var confirm: null
  property real nowSec: Date.now() / 1000

  readonly property var filtered: Model.filterRows(rowsAll, filter, query)
  readonly property var flat: Model.flatten(Model.sections(filtered), collapsed)
  readonly property int selectedCount: Object.keys(selected).length

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)

  readonly property bool showCount: flag("showCount", true) && sum.dev > 0
  readonly property bool hidden: flag("hideWhenEmpty", false) && sum.dev === 0 && sum.exposed === 0

  function flag(name, fallback) {
    return Model.coerce(settings ? settings[name] : undefined, fallback)
  }

  readonly property var filterOptions: [
    { value: "dev", label: "Dev", tooltip: "Dev servers and containers (1)" },
    { value: "mine", label: "Mine", tooltip: "Everything you own (2)" },
    { value: "exposed", label: "Exposed", tooltip: "Reachable from the network (3)" },
    { value: "all", label: "All", tooltip: "Every listening socket (4)" }
  ]

  // ---------------------------------------------------------------- service

  function resolveService() {
    if (service || !bar || !bar.shell || typeof bar.shell.serviceFor !== "function") return
    service = bar.shell.serviceFor(moduleName)
    if (service) service.applySettings(settings)
  }

  onSettingsChanged: if (service) service.applySettings(settings)
  onBarChanged: resolveService()

  Timer {
    // The service can load after the widget; keep asking until it is there.
    interval: 500
    repeat: true
    running: !root.service
    triggeredOnStart: true
    onTriggered: root.resolveService()
  }

  Connections {
    target: root.service
    function onDetailsRequested(key) { root.showRow(key) }
    function onToggleRequested() { root.toggle() }
  }

  function persist(patch) {
    var next = Object.assign({}, root.settings, patch)
    root.settings = next
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, next)
  }

  // ---------------------------------------------------------------- view

  function showRow(key) {
    filter = "all"
    query = ""
    var c = Object.assign({}, collapsed)
    for (var i = 0; i < filtered.length; i++) if (filtered[i].key === key) {
      var sec = Model.sections([filtered[i]])[0]
      if (sec) delete c[sec.id]
    }
    collapsed = c
    open()
  }

  function toggleSection(id) {
    var c = Object.assign({}, collapsed)
    if (c[id]) delete c[id]
    else c[id] = true
    collapsed = c
  }

  function setFilter(value) {
    filter = value
  }

  // ---------------------------------------------------------------- targets

  function selectedRows() {
    return filtered.filter(function(r) { return selected[r.key] })
  }

  function toggleSelected(row) {
    if (!row) return
    var s = Object.assign({}, selected)
    if (s[row.key]) delete s[row.key]
    else s[row.key] = true
    selected = s
  }

  function openRows(rows) {
    rows.filter(Model.canOpen).forEach(function(r) { service.open(r) })
  }

  function askStop(rows, forceKill) {
    rows = rows.filter(Model.canStop)
    if (!rows.length || !service) return
    var plans = rows.map(function(r) { return service.stopPlan(r) })
    var kill = forceKill || plans.some(function(p) { return p.kill })
    var msg
    if (rows.length === 1) {
      var r = rows[0], p = plans[0]
      msg = (kill ? "Force kill " : "Stop ") + Model.title(r)
      msg += r.container ? " (" + r.container.runtime + " " + r.container.name + ")?"
                         : " (" + r.comm + ", pid " + r.pid + ")?"
      if (p.parent) msg += "\nAlso stops its " + p.parent.comm + " wrapper (pid " + p.parent.pid + ")."
    } else {
      msg = (kill ? "Force kill " : "Stop ") + rows.length + " servers?\n"
        + rows.map(function(r) { return Model.title(r) }).join(", ")
    }
    confirm = { rows: rows, kill: kill, message: msg, confirmText: kill ? "Force kill" : "Stop" }
  }

  function confirmed() {
    var c = confirm
    confirm = null
    if (!c || !service) return
    c.rows.forEach(function(r) { service.stop(r, c.kill) })
    selected = ({})
  }

  function canceled() {
    confirm = null
  }

  onOpenedChanged: {
    if (opened) {
      nowSec = Date.now() / 1000
      selected = ({})
      confirm = null
    } else {
      query = ""
    }
  }

  Timer {
    interval: 15000
    repeat: true
    running: root.opened
    onTriggered: root.nowSec = Date.now() / 1000
  }

  visible: !hidden
  implicitWidth: hidden ? 0 : button.implicitWidth
  implicitHeight: hidden ? 0 : button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showCount && !vertical ? "󰒍 " + root.sum.dev : "󰒍"
    slotSize: Style.bar.iconSlot * (root.showCount && !vertical ? 1.8 : 1)
    active: root.sum.exposed > 0
    tooltipText: root.service ? Model.tooltip(root.sum) : "Portside is starting"
    onPressed: function(b) {
      if (b === Qt.RightButton) { if (root.service) root.service.refresh() }
      else if (b === Qt.MiddleButton) {
        var dev = root.rowsAll.filter(function(r) { return r.group === "dev" && Model.canOpen(r) })
        dev.sort(function(a, c) { return (c.startedAt || 0) - (a.startedAt || 0) })
        if (dev.length) root.service.open(dev[0])
      }
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panelRoot
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    // Mouse-driven panel: the only key it handles is Esc, to close.
    Item {
      id: panelRoot
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: {
        if (root.confirm) root.canceled()
        else root.close()
      }

      Item {
        id: content
        width: parent.width
        implicitHeight: column.implicitHeight

        Column {
          id: column
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Ports"
            meta: !root.service || !root.service.ready ? "Scanning"
              : root.sum.exposed ? root.sum.exposed + " open to the network"
              : root.sum.dev === 1 ? "1 dev server" : root.sum.dev + " dev servers"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰒍"
                color: root.sum.exposed ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                checked: root.flag("alerts", true)
                foreground: root.foreground
                cursorRing: false
                onToggled: root.persist({ alerts: !checked })

                PanelToolTip {
                  visible: parent.containsMouse
                  text: parent.checked ? "Alerts on" : "Alerts off"
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          TextField {
            id: searchField
            width: parent.width
            placeholderText: "Filter by port, project, process…"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            foreground: root.foreground
            text: root.query
            onTextChanged: if (text !== root.query) root.query = text
            Keys.onEscapePressed: function(event) {
              if (text !== "") root.query = ""
              else root.close()
              event.accepted = true
            }
          }

          ButtonGroup {
            id: filterGroup
            options: root.filterOptions
            value: root.filter
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(value) { root.setFilter(value) }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.service ? (root.service.status || root.service.helperError) : ""
            color: root.service && (root.service.statusIsError || root.service.helperError) ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator { foreground: root.foreground }

          ListView {
            id: list
            width: parent.width
            height: Math.min(contentHeight, Style.space(420))
            spacing: Style.space(4)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.flat

            delegate: Column {
              id: entry
              required property var modelData
              required property int index
              width: ListView.view.width
              spacing: Style.space(4)

              Item {
                visible: entry.modelData.section !== ""
                width: parent.width
                height: visible ? header.implicitHeight + Style.space(6) : 0

                PanelSectionHeader {
                  id: header
                  anchors.left: parent.left
                  anchors.bottom: parent.bottom
                  text: entry.modelData.section.toUpperCase()
                    + (entry.modelData.collapsed ? "  ·  " + entry.modelData.hiddenCount + " hidden" : "")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleSection(entry.modelData.sectionId)
                }
              }

              PortRow {
                visible: !entry.modelData.collapsed
                width: parent.width
                listener: entry.modelData.row
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.flat.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: !root.service || !root.service.ready ? "Scanning…"
              : root.query !== "" ? "Nothing matches “" + root.query + "”."
              : root.filter === "exposed" ? "Nothing is reachable from the network."
              : root.filter === "dev" ? "No dev servers running."
              : "Nothing is listening."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // Shown while rows are selected (right-click or Ctrl-click a row).
          Row {
            visible: root.selectedCount > 0
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: root.selectedCount + " selected"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Item { width: Style.space(4); height: 1 }
            SelectionButton { text: "Open"; onClicked: root.openRows(root.selectedRows()) }
            SelectionButton { text: "Copy"; onClicked: root.service.copyUrl(root.selectedRows()) }
            SelectionButton { text: "Stop"; onClicked: root.askStop(root.selectedRows(), false) }
            SelectionButton { text: "Clear"; onClicked: root.selected = ({}) }
          }
        }

        ConfirmDialog {
          id: confirmDialog
          anchors.fill: parent
          z: 10
          opened: root.confirm !== null
          message: root.confirm ? root.confirm.message : ""
          confirmText: root.confirm ? root.confirm.confirmText : "Stop"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onConfirmed: root.confirmed()
          onCanceled: root.canceled()
        }
      }
    }
  }

  component PortRow: CursorSurface {
    id: portRow
    required property var listener

    readonly property var reach: Model.reachInfo(listener.reach)
    readonly property bool isSelected: !!root.selected[listener.key]
    readonly property bool watched: root.service ? root.service.isWatched(listener) : false
    readonly property bool busy: root.service ? !!root.service.busyKeys[listener.key] : false
    // A HoverHandler stays hovered while the pointer is over the row's own
    // buttons, where a MouseArea would report the pointer as gone.
    readonly property bool showActions: rowHover.hovered
    readonly property color toneColor: reach.tone === "urgent" ? root.urgent
      : reach.tone === "warn" ? Color.accent
      : reach.tone === "normal" ? root.foreground : root.dim

    hasCursor: rowHover.hovered
    current: isSelected
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
    opacity: busy ? 0.55 : 1

    HoverHandler { id: rowHover }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      cursorShape: Model.canOpen(portRow.listener) ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton || (mouse.modifiers & Qt.ControlModifier)) root.toggleSelected(portRow.listener)
        else if (mouse.button === Qt.MiddleButton) root.service.copyUrl([portRow.listener])
        else root.openRows([portRow.listener])
      }
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      implicitHeight: Math.max(info.implicitHeight, trailing.implicitHeight)

      Rectangle {
        id: dot
        width: Style.space(7)
        height: width
        radius: width / 2
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        color: portRow.isSelected ? Color.accent : portRow.toneColor
      }

      Column {
        id: info
        anchors.left: dot.right
        anchors.leftMargin: Style.space(10)
        anchors.right: trailing.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        // Hovering the text (not the action buttons) shows the full details.
        HoverHandler { id: infoHover }

        PanelToolTip {
          visible: infoHover.hovered
          delay: 700
          text: [
            portRow.listener.cmd && portRow.listener.cmd.length ? portRow.listener.cmd.join(" ") : "",
            portRow.listener.cwd || "",
            portRow.listener.addrs.join(", ") + " · " + (portRow.listener.reachNote || "")
          ].filter(function(s) { return s !== "" }).join("\n")
          fontFamily: root.fontFamily
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            id: titleText
            textFormat: Text.PlainText
            text: Model.title(portRow.listener)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
            width: Math.min(implicitWidth, parent.width - extra.implicitWidth - star.implicitWidth - Style.space(12))
          }
          Text {
            id: extra
            textFormat: Text.PlainText
            text: Model.extraPorts(portRow.listener)
            visible: text !== ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.baseline: titleText.baseline
          }
          Text {
            id: star
            textFormat: Text.PlainText
            text: "󰓎"
            visible: portRow.watched
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: titleText.verticalCenter
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: portRow.busy ? "Stopping…" : Model.subtitle(portRow.listener, root.nowSec)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: trailing
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Row {
          visible: portRow.showActions && !portRow.busy
          spacing: Style.space(2)
          anchors.verticalCenter: parent.verticalCenter

          RowAction {
            iconText: "󰖟"
            tooltipText: "Open " + Model.url(portRow.listener)
            visible: Model.canOpen(portRow.listener)
            onClicked: root.openRows([portRow.listener])
          }
          RowAction {
            iconText: "󰆏"
            tooltipText: "Copy URL"
            onClicked: root.service.copyUrl([portRow.listener])
          }
          RowAction {
            iconText: "󰆍"
            tooltipText: "Terminal in " + (portRow.listener.project || portRow.listener.cwd || "")
            visible: !!(portRow.listener.project || portRow.listener.cwd)
            onClicked: root.service.terminal(portRow.listener)
          }
          RowAction {
            iconText: portRow.watched ? "󰓎" : "󰓒"
            tooltipText: portRow.watched ? "Stop watching" : "Watch: alert if it goes down"
            visible: portRow.listener.mine
            onClicked: root.persist({ watched: root.service.toggledWatch(portRow.listener) })
          }
          RowAction {
            iconText: "󰓛"
            tooltipText: portRow.listener.container ? "Stop container" : "Stop"
            visible: Model.canStop(portRow.listener)
            hoverColor: root.urgent
            onClicked: root.askStop([portRow.listener], false)
          }
        }

        BorderSurface {
          implicitWidth: pill.implicitWidth + Style.space(10)
          implicitHeight: pill.implicitHeight + Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          color: "transparent"
          borderSpec: Border.flat(Util.alpha(portRow.toneColor, 0.6), Style.normalBorderWidth)
          radius: Style.cornerRadius

          Text {
            id: pill
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: portRow.reach.label
            color: portRow.toneColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }
  }

  component SelectionButton: Button {
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    bordered: true
  }

  component RowAction: PanelActionButton {
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.body
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
  }
}
