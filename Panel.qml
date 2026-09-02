import QtQuick
import QtQuick.Controls
import Qt.labs.folderlistmodel
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button plus popup for the VPN connections.
// Button and panel live in one file because KeyboardPanel has to point its
// anchorItem at the button.
Panel {
  id: root
  moduleName: "smartalb.vpn"
  ipcTarget: "smartalb.vpn"
  manageIpc: true

  // A second copy of what manifest.json says -- QML cannot reach the
  // manifest (Omarchy's PluginRegistry is an instance, not a singleton).
  // test_panel_version_matches_the_manifest keeps the two from drifting.
  readonly property string pluginVersion: "1.2.2"

  property var connections: []
  property string loadError: ""
  property string toggleError: ""

  // --- Add connection ---
  property bool addOpen: false
  property string addError: ""
  property string addKind: ""       // "openvpn" | "wireguard" | ""
  property string addRemote: ""
  // The path of the chosen file. Not a secret (unlike its content), so it
  // is shown.
  property string addPath: ""
  property int addBytes: 0
  property bool addEmbedded: false
  property string addLabel: ""
  property string addGroup: ""
  property bool addBusy: false
  // True while the file list is expanded. It is NOT a window of its own
  // (the reason is in the header comment of folderModel) but part of this
  // panel -- so the flag belongs to the draft state of the add section and
  // is discarded along with it.
  property bool addBrowsing: false
  // The folder whose content the list shows. Deliberately NOT part of the
  // draft state: whoever browsed somewhere should carry on there the next
  // time the list opens. "/" is the initial value so the list shows a
  // readable folder even when startDirProc delivers nothing -- that way no
  // dead end can arise.
  property string browseDir: "/"

  // --- Remove ---
  property string removeId: ""
  property string removeUnit: ""
  property bool removeAlsoFile: false
  // Its own error field instead of sharing root.addError (fix round 1):
  // manageProc serves both directions, but success or failure of "Remove"
  // has to be visible independently of addOpen AND must not accidentally
  // surface in the add section when both sections happen to be open at the
  // same time. Two fields instead of one plus a mode flag keep the
  // visibility bindings below simple and free of special cases.
  property string removeError: ""

  // Which of the two manageProc calls ran last -- it steers only which of
  // the two error fields above the stderr handler writes to, and which
  // reset runs after success. To resolve the contrast: root.addError is
  // ALSO still written by inspectProc (File not readable, verdict
  // rejected) -- that is independent of the manageProc run and needs no
  // distinction of its own, it always belongs to the add section.
  property string manageAction: ""

  // Collapses the add section and discards its draft state -- shared by
  // the Cancel button, by closing the panel and by the success case of
  // creating. The configuration content itself is never held here (only
  // the verdict and the label), yet it too is discarded as soon as the
  // section is closed.
  function resetAddSection() {
    root.addKind = ""; root.addLabel = ""; root.addGroup = ""
    root.addPath = ""; root.addRemote = ""; root.addError = ""
    // The file list collapses with it. root.browseDir deliberately stays
    // where it is, see there.
    root.addBrowsing = false
    // See the comment at labelField: text: root.addLabel binds only once,
    // after the first keystroke the field has to be cleared by hand.
    labelField.text = ""; groupField.text = ""
  }

  // Discards a row's confirmation prompt -- shared by the Cancel button,
  // by closing the panel and by the success case of removing.
  function resetRemoveSection() {
    root.removeId = ""; root.removeUnit = ""; root.removeAlsoFile = false
    root.removeError = ""
  }

  // Mirrors the derivation in bin/omarchy-vpn-add -- for the preview only.
  // The script is authoritative; if the two ever differ, what the script
  // does is what counts.
  function derivedName(label, kind) {
    var s = String(label || "").replace(/[^A-Za-z0-9_.\-]/g, "_")
    s = s.replace(/^-+/, "")
    if (s === "." || s === "..") s = ""
    return s.substring(0, kind === "wireguard" ? 15 : 64)
  }

  readonly property string addName: derivedName(root.addLabel, root.addKind)
  readonly property string addUnit: root.addKind === "wireguard"
    ? "wg-quick@" + root.addName
    : "openvpn-client@" + root.addName

  // Nerd Font glyphs as escapes, not as literal characters: the code
  // points sit in the Unicode private use area and do not reliably survive
  // being copied through documents and tools. An empty text makes the
  // BarIconButton invisible (hasVisualContent: text !== ""), not merely
  // symbol-less.
  readonly property string glyphLocked: "\uF023"   // nf-fa-lock
  readonly property string glyphOpen: "\uF09C"     // nf-fa-unlock
  readonly property string glyphFolder: "\uF07B"   // nf-fa-folder
  readonly property string glyphFile: "\uF15B"     // nf-fa-file
  readonly property string glyphUp: "\uF062"       // nf-fa-arrow_up

  // Without these two lines the bar slot measures zero and the button
  // stays invisible: Panel is a plain Item with no content size of its own.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string scriptDir: Qt.resolvedUrl(".").toString().replace("file://", "") + "/bin"

  // Two derived properties instead of sixteen unguarded
  // root.bar.foreground/root.bar.fontFamily accesses in the popup content:
  // the bar injects its properties only after the first render, so "bar"
  // can be null for a moment (which is why the bar button below has long
  // been guarded). Falls back to the global singletons from qs.Commons --
  // the same values Color/Style themselves would fall back to.
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFam: root.bar ? root.bar.fontFamily : Style.fontFamily

  function shellEscape(s) {
    if (s === undefined || s === null) return "''"
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function activeConnections() {
    var out = []
    for (var i = 0; i < root.connections.length; i++)
      if (root.connections[i].state === "active") out.push(root.connections[i])
    return out
  }

  readonly property var activeList: activeConnections()

  function tooltipText() {
    var a = root.activeList
    if (a.length === 0) return "No VPN connection"
    var names = []
    for (var i = 0; i < a.length; i++) names.push(String(a[i].label))
    return names.join("  \u00B7  ")
  }

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  // Deliberately NOT named toggle(): the Panel base class ships a method
  // of that name with which the bar button opens the popup. A toggle() of
  // our own would shadow it and the button would stop reacting.
  function toggleConnection(id) {
    if (toggleProc.running) return
    root.toggleError = ""
    toggleProc.command = ["bash", "-c", root.scriptDir + "/omarchy-vpn-toggle " + shellEscape(id)]
    toggleProc.running = true
    // The panel deliberately stays open: the state change takes seconds
    // and should be visible.
  }

  // Turns a filesystem path into a file: URL -- FolderListModel.folder is
  // a QUrl. Every name component is encoded INDIVIDUALLY; a plain
  // "file://" + path is not enough: QUrl read a folder named "100%41" as
  // an escape and descended into "100A". Measured with Qt 6.11 on folders
  // with spaces and with percent signs, see the report.
  //
  // Nobody needs the way back URL -> path any more: the list already hands
  // out a finished path in its filePath role. That is why urlToPath()
  // is gone.
  function pathToUrl(p) {
    var parts = String(p || "").split("/")
    for (var i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i])
    return "file://" + parts.join("/")
  }

  // The parent folder, computed purely on the path instead of via
  // FolderListModel.parentFolder: that saves the way back URL -> path and
  // still carries even when the model could not read the current folder at
  // all. "" means "there is none above" -- true only in "/".
  function parentDir(p) {
    var s = String(p || "")
    if (s === "" || s === "/") return ""
    var i = s.lastIndexOf("/")
    if (i <= 0) return "/"
    return s.substring(0, i)
  }

  // Expands or collapses the file list. No dialog, no window, no portal --
  // the reason is in the header comment of folderModel. It is at the same
  // time the way back out without picking a file.
  function toggleBrowser() {
    if (root.addBusy) return
    root.addError = ""
    root.addBrowsing = !root.addBrowsing
  }

  // A click on a file in the list: take it over and have it checked.
  function pickFile(path) {
    if (root.addBusy) return
    if (path === "") { root.addError = "No file path recognized"; return }
    root.addPath = path
    root.addBrowsing = false
    root.inspectFile(path)
  }

  // Has the chosen file judged.
  function inspectFile(path) {
    if (root.addBusy) return
    root.addBusy = true
    root.addError = ""
    root.addKind = ""
    inspectProc.command = ["bash", "-c",
      "cat -- " + root.shellEscape(path) + " 2>/dev/null | "
      + root.scriptDir + "/omarchy-vpn-inspect"]
    inspectProc.running = true
  }

  function createConnection() {
    if (root.addBusy) return
    if (root.addPath === "") { root.addError = "Pick a configuration file first"; return }
    if (root.addKind === "") { root.addError = "The chosen file was not accepted"; return }
    if (root.addName === "") { root.addError = "Label yields no valid name"; return }
    root.addBusy = true
    root.addError = ""
    root.manageAction = "add"
    // The PATH goes to omarchy-vpn-add -- that runs as the user and reads
    // the file itself. Only its content travels on to the privileged
    // program; see the header comment of bin/omarchy-vpn-add.
    manageProc.command = ["bash", "-c",
      root.scriptDir + "/omarchy-vpn-add " + root.shellEscape(root.addPath)
      + " " + root.shellEscape(root.addLabel)
      + (root.addGroup !== "" ? " " + root.shellEscape(root.addGroup) : "")]
    manageProc.running = true
  }

  function forgetConnection() {
    if (root.addBusy || root.removeId === "") return
    root.addBusy = true
    root.removeError = ""
    root.manageAction = "forget"
    manageProc.command = ["bash", "-c",
      root.scriptDir + "/omarchy-vpn-forget " + root.shellEscape(root.removeId)
      + " " + root.shellEscape(root.removeUnit)
      + (root.removeAlsoFile ? " --also-file" : "")]
    manageProc.running = true
  }

  // Fix round 1: without the else branch an open confirmation prompt
  // (removeId) or an expanded add section (addOpen) survives the closing of
  // the panel -- even though the connection list is reloaded on the next
  // open and the row in question may not even exist any more. addBusy is
  // deliberately left alone: a running process keeps running, closing the
  // panel does not abort it.
  //
  // There used to be an exception here ("only clean up when no path is
  // chosen and no dialog is open"). It had exactly one reason: the file
  // dialog was a WINDOW OF ITS OWN and could take the focus away from the
  // panel -- a layer-shell surface -- so that the panel closed in the
  // middle of the selection; the user would otherwise have come back from
  // the dialog into an empty panel. The file list now lives INSIDE the
  // panel, there is no foreign focus taker left. If the panel closes, the
  // user closed it -- and then it is cleaned up, without exception. Along
  // with the exception, addPicking, fileDialog.onRejected and the deferred
  // cleanup there fall away with nothing to replace them.
  //
  // The cleanup promises still hold:
  //  * No message is lost. If a message from manageProc arrives after
  //    addOpen was set to false here, the catch-all further down shows it
  //    ("Add (background): ...").
  //  * Nothing appears twice. The two displays still hang off addOpen
  //    (true in addColumn, false at the catch-all) and exclude each other.
  //  * A cancelled operation leaves nothing behind: resetAddSection() also
  //    takes addBrowsing back.
  //  * A running privileged operation is not seemingly aborted: addBusy is
  //    not touched here, the buttons stay locked, and its result finds its
  //    place above.
  onOpenedChanged: {
    if (opened) {
      refresh()
    } else {
      root.resetRemoveSection()
      root.addOpen = false
      root.resetAddSection()
    }
  }

  // The file picker. A PLAIN DATA MODEL from Qt.labs.folderlistmodel: it
  // reads a directory and exposes the entries as model roles. It creates no
  // window, speaks no D-Bus and registers with no xdg-desktop-portal. That
  // is exactly what the earlier FileDialog foundered on: Qt registered it
  // with the portal, but Quickshell's D-Bus connection already carried an
  // application id (Omarchy's polkit agent had registered seconds before),
  // the registration failed, and gio aborted the WHOLE process while
  // building the message -- the bar vanished. Whatever stands here must
  // therefore never create a window again.
  //
  // nameFilters applies to files only; folders stay visible regardless
  // (QDir::AllDirs). showOnlyReadable keeps unreadable entries out.
  FolderListModel {
    id: folderModel
    folder: root.pathToUrl(root.browseDir)
    nameFilters: ["*.ovpn", "*.conf"]
    showDirs: true
    showDirsFirst: true
    showFiles: true
    showDotAndDotDot: false
    showHidden: false
    showOnlyReadable: true
    sortField: FolderListModel.Name
  }

  // Starting directory of the file list: ~/Downloads if it exists, else the
  // home directory. Determined once at startup. The test against "/" is the
  // precaution for the case that the user was faster than the process: then
  // wherever they browsed to stays put.
  Process {
    id: startDirProc
    running: true
    command: ["bash", "-c",
      'if [ -d "$HOME/Downloads" ]; then printf %s "$HOME/Downloads"; else printf %s "$HOME"; fi']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = String(text || "").trim()
        if (d !== "" && root.browseDir === "/") root.browseDir = d
      }
    }
  }

  Process {
    id: listProc
    command: ["bash", "-c", root.scriptDir + "/omarchy-vpn-list --json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (raw.trim() === "") {
          root.connections = []
          root.loadError = "Connection list not readable"
          return
        }
        try {
          var data = JSON.parse(raw)
          if (Array.isArray(data)) {
            root.connections = data
            root.loadError = ""
          } else {
            root.connections = []
            root.loadError = String((data && data.error) || "Connection list not readable")
          }
        } catch (e) {
          root.connections = []
          root.loadError = "Connection list not readable"
        }
      }
    }
  }

  Process {
    id: toggleProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text || "").trim()
        if (msg !== "") root.toggleError = msg.split("\n").pop()
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0) root.toggleError = ""
      root.refresh()
    }
  }

  // Reads the chosen file and has it judged. The content travels through
  // the pipe only -- it lands in no property, is never displayed and is
  // stored nowhere: an .ovpn contains the private key. The PATH is not a
  // secret and is displayed.
  //
  // command is assigned in inspectFile(), not bound: a binding on
  // root.addPath would already re-run when the path is set, and the process
  // would then have two triggers instead of one.
  Process {
    id: inspectProc
    // addBusy is taken back in onExited, NOT here: if Process.running is
    // still true when streamFinished arrives, the "running = true" of the
    // next selection would have no effect -- addBusy would then stay true
    // forever and every button stay locked. manageProc has always done it
    // this way for the same reason.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") {
          root.addKind = ""
          root.addError = "File not readable"
          return
        }
        try {
          var d = JSON.parse(raw)
          if (d.ok) {
            root.addKind = String(d.kind || "")
            root.addRemote = String(d.remote || "")
            root.addBytes = Number(d.bytes || 0)
            root.addEmbedded = d.embedded === true
            root.addError = ""
          } else {
            root.addKind = ""
            root.addError = (d.line !== undefined ? "Line " + d.line + ": " : "") +
                            String(d.error || "Unusable input")
          }
        } catch (e) {
          root.addKind = ""
          root.addError = "Unexpected answer from the check"
        }
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.addBusy = false
    }
  }

  // One process for both directions: the ordering (file before entry,
  // entry before file) lives in the scripts, not here -- that is where it
  // is tested.
  Process {
    id: manageProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text || "").trim()
        if (msg === "") return
        // Important (fix round 1): a failed removal has to be visible even
        // when addOpen is closed -- hence into the matching field, never
        // blindly into root.addError.
        if (root.manageAction === "forget") root.removeError = msg.split("\n").pop()
        else root.addError = msg.split("\n").pop()
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.addBusy = false
      if (exitCode === 0) {
        // Only reset the branch that actually ran -- fix round 1: otherwise
        // a typed label is lost when another row is removed in between (and
        // conversely an open confirmation prompt is lost when a new
        // connection is created).
        if (root.manageAction === "add") {
          root.addOpen = false
          root.resetAddSection()
        } else if (root.manageAction === "forget") {
          root.resetRemoveSection()
        }
      }
      root.refresh()
    }
  }

  Timer {
    // Keeps the bar button up to date even when someone switches a
    // connection outside the panel -- through the old desktop entries, say.
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.activeList.length > 0 ? root.glyphLocked : root.glyphOpen
    // Bar.qml has no "accent" -- every first-party panel (tailscale,
    // network, audio, bluetooth, ...) falls back to the global Color.accent
    // for this, never to bar.accent. A deviation from the task brief, see
    // the report.
    foreground: root.activeList.length > 0 ? Color.accent : root.fg
    opacity: root.activeList.length > 0 ? 1.0 : 0.55
    tooltipText: root.tooltipText()
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(320))
    // No fixed upper bound any more: the content grows with the connection
    // list (Repeater, every row with a remove button) and with the expanded
    // add section (summary, two text fields, unit preview, create button).
    // With three connections Style.space(420) already burst the panel
    // before the "Create" button. The network and the bluetooth panel have
    // the same build -- growing list plus form area -- and call
    // fittedContentHeight() without a second argument; this follows them.
    // The function itself stays bounded by the screen (see
    // availableCardHeight in KeyboardPanel.qml), so "unbounded" still means
    // "as tall as sensibly fits on the screen", not limitless.
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    // A ScrollView so that a growing connection list scrolls instead of
    // being cut off -- and because KeyboardPanel brings no availableWidth
    // of its own while ScrollView does.
    ScrollView {
      id: scrollArea
      anchors.fill: parent
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
      ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

    Column {
      id: panelColumn
      width: scrollArea.availableWidth
      spacing: Style.space(4)

      PanelSectionHeader {
        text: "VPN"
        foreground: root.fg
        fontFamily: root.fontFam
      }

      Text {
        width: panelColumn.width
        visible: root.loadError !== ""
        text: root.loadError
        color: root.fg
        font.family: root.fontFam
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        width: panelColumn.width
        visible: root.loadError === "" && root.connections.length === 0
        text: "No connections registered. See ~/.config/omarchy/vpn-connections.json"
        color: root.fg
        opacity: 0.7
        font.family: root.fontFam
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // Fix round 2: catch-all for a message from REMOVING whose proper
      // display (confirmColumn) can no longer show it. The case is still
      // reachable: if the panel closes while a removal is running,
      // onOpenedChanged resets removeId and removeError -- the message from
      // manageProc arrives only AFTERWARDS and finds removeId === "".
      // The condition is disjoint from the regular display: removeId is
      // either "" (here) or equal to some modelData.id (there), so the
      // message can never appear twice.
      Text {
        width: panelColumn.width
        visible: root.removeError !== "" && root.removeId === ""
        text: "Remove (background): " + root.removeError
        color: root.fg
        font.family: root.fontFam
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // The counterpart for the add section -- and, since the file list, a
      // display that really does fire again: if the panel closes while a
      // "Create" is running, onOpenedChanged cleans up without exception
      // (addOpen becomes false), and the message from manageProc arrives
      // only AFTERWARDS. Without this place it would be lost in silence --
      // and that is exactly what once cost two fix rounds.
      //
      // The condition is disjoint from the display in addColumn (addOpen
      // false here, true there), so nothing can appear twice.
      Text {
        width: panelColumn.width
        visible: root.addError !== "" && !root.addOpen
        text: "Add (background): " + root.addError
        color: root.fg
        font.family: root.fontFam
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Repeater {
        model: root.connections

        Rectangle {
          required property var modelData

          width: panelColumn.width
          // outerColumn automatically leaves root.removeId === modelData.id
          // (the invisible confirmation block) out of the height -- a Column
          // does not count invisible children.
          implicitHeight: outerColumn.implicitHeight + Style.spacing.sm * 2
          radius: Style.cornerRadius
          color: (rowMouse.containsMouse && !toggleProc.running) ? Style.hoverFill : "transparent"
          opacity: toggleProc.running ? 0.45 : 1.0

          Column {
            id: outerColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Style.spacing.sm
            anchors.rightMargin: Style.spacing.sm
            anchors.topMargin: Style.spacing.sm
            spacing: Style.space(4)

            // The row proper: text on the left, remove button on the right.
            // The row's MouseArea (rowMouse) switches the connection; the
            // button sits as the last child AND explicitly above it with
            // z: 1 so that a click on the cross does not end up at rowMouse.
            // See the report for the evidence without a running widget.
            Item {
              id: rowTop
              width: outerColumn.width
              implicitHeight: Math.max(rowColumn.implicitHeight, removeButton.implicitHeight)
              height: implicitHeight

              Column {
                id: rowColumn
                anchors.left: parent.left
                anchors.right: removeButton.left
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: (modelData.state === "active" ? "\u25CF  " : "") + modelData.label
                  color: root.fg
                  font.family: root.fontFam
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: modelData.state === "active" ? "connected"
                        : modelData.state === "failed" ? "failed -- journalctl -u " + modelData.unit
                        : "disconnected"
                  color: root.fg
                  opacity: modelData.state === "failed" ? 0.9 : 0.6
                  font.family: root.fontFam
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: rowMouse
                z: 0
                anchors.fill: parent
                hoverEnabled: !toggleProc.running
                enabled: !toggleProc.running
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleConnection(modelData.id)
              }

              PanelActionButton {
                id: removeButton
                z: 1
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "\uF00D"          // nf-fa-times
                tooltipText: "Remove"
                foreground: root.fg
                fontFamily: root.fontFam
                onClicked: {
                  root.removeId = modelData.id
                  root.removeUnit = modelData.unit
                  root.removeAlsoFile = false
                  // Otherwise the error of a previous, different row
                  // would be left standing here.
                  root.removeError = ""
                }
              }
            }

            // Confirmation prompt: visible only while this very row is in
            // the middle of a removal.
            Column {
              id: confirmColumn
              visible: root.removeId === modelData.id
              width: outerColumn.width
              spacing: Style.space(4)

              // The default stays "off" -- removing only the list entry is
              // the more harmless half-state. But its consequence has to be
              // spelled out: without the tick the file stays behind, and
              // without a list entry the widget has no handle on it any more
              // (omarchy-vpn-forget needs id and unit from the list). The
              // way back leads through importing the same file again -- the
              // import accepts a byte-identical existing file.
              Toggle {
                width: parent.width
                label: "also delete the file"
                description: "Without the tick the file stays behind in /etc and is no longer reachable through the widget."
                checked: root.removeAlsoFile
                foreground: root.fg
                fontFamily: root.fontFam
                onClicked: root.removeAlsoFile = !root.removeAlsoFile
              }

              // The two buttons of the confirmation prompt. Formerly
              // WidgetButton plus a MouseArea laid over it -- that was plain
              // text without a surface. Now Button from qs.Ui (see the long
              // comment at addToggleButton further down, which also explains
              // why the name resolves to qs.Ui.Button).
              //
              // The lock during a running operation is unchanged: the same
              // condition, only no longer on the MouseArea but on the button
              // itself -- in QML `enabled` disables the child's MouseArea
              // along with it. The opacity next to it is pure display and
              // makes the lock visible for the first time.
              Row {
                spacing: Style.spacing.lg

                Button {
                  id: confirmForgetButton
                  text: root.addBusy ? "Please wait ..." : "Remove"
                  enabled: !root.addBusy
                  opacity: confirmForgetButton.enabled ? 1.0 : 0.45
                  foreground: root.fg
                  fontFamily: root.fontFam
                  fontSize: Style.font.bodySmall
                  bordered: true
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                  onClicked: root.forgetConnection()
                }

                Button {
                  id: confirmCancelButton
                  text: "Cancel"
                  // Fix round 1: without this `enabled`, "Cancel" only
                  // feigns an abort -- the removal carries on in the
                  // background, merely the prompt disappears. Locked like
                  // its neighbor "Remove".
                  enabled: !root.addBusy
                  opacity: confirmCancelButton.enabled ? 1.0 : 0.45
                  foreground: root.fg
                  fontFamily: root.fontFam
                  fontSize: Style.font.bodySmall
                  bordered: true
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                  onClicked: root.resetRemoveSection()
                }
              }

              // Important (fix round 1): visible independently of addOpen,
              // because the prompt (and with it this text) already hangs off
              // root.removeId === modelData.id -- a failed removal (exit
              // 1/15/16 of omarchy-vpn-forget, among them "entry removed,
              // the file stayed behind") thus stays visible until the user
              // sees it or cancels.
              Text {
                width: parent.width
                visible: root.removeError !== ""
                text: root.removeError
                color: root.fg
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

      Text {
        width: panelColumn.width
        visible: toggleProc.running
        text: "Switching ..."
        color: root.fg
        opacity: 0.7
        font.family: root.fontFam
        font.pixelSize: Style.font.caption
      }

      PanelSeparator {
        visible: root.toggleError !== ""
        foreground: root.fg
      }

      Text {
        width: panelColumn.width
        visible: root.toggleError !== ""
        text: root.toggleError
        color: root.fg
        font.family: root.fontFam
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      PanelSeparator {
        foreground: root.fg
      }

      // Until this round a WidgetButton with a MouseArea of its own laid
      // over it stood here. WidgetButton belongs in the BAR: a plain Item
      // that only draws a text -- no surface, no border, no hover feedback,
      // no clicked signal. Inside the panel that read as a caption rather
      // than as a button.
      //
      // Button from qs.Ui is the toolkit's button: a surface of its own, a
      // border via `bordered`, hover/focus/pressed states and a clicked
      // signal. The first-party panels are the model:
      //   * power/Panel.qml:480ff  -- Button with an explicit width across
      //     the full row, bordered, the same padding tokens
      //   * network/Panel.qml:1533ff (BandPill) and :1565ff
      //     (DnsProviderPill) -- Button as a text button with bordered
      // PanelActionButton does NOT fit here: it is square via `size` and
      // built around `iconText` (which is why the remove cross above uses
      // it, but no text button does).
      //
      // NO color is fixed here. Button derives fill and border internally
      // from Style.hoverFillFor/pressedFillFor/normalFillFor and
      // Border.controlSpec; we hand in only root.fg (from bar.foreground
      // or Color.foreground) and root.fontFam.
      //
      // The name "Button" resolves to qs.Ui.Button, not to
      // QtQuick.Controls.Button: on a name collision the import read LAST
      // wins, and qs.Ui is last in the import list at the top.
      // plugins/panels/network/Panel.qml imports the same two modules in
      // the same order and likewise writes just "Button {".
      Button {
        id: addToggleButton
        width: panelColumn.width
        text: root.addOpen ? "Cancel" : "Add connection"
        foreground: root.fg
        fontFamily: root.fontFam
        bordered: true
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
        onClicked: {
          root.addOpen = !root.addOpen
          root.addError = ""
          // Formerly an open file dialog had to be closed here as well.
          // There is no window any more; the list collapses along with
          // resetAddSection() (addBrowsing).
          if (!root.addOpen) root.resetAddSection()
        }
      }

      // STRUCTURE (the second point of this round): the add section used to
      // hang at the bottom of the panel on the same level as the connection
      // list -- nothing showed that something other than switching was
      // going on there. It now stands in a set-apart surface of its own
      // with a border and its own heading.
      //
      // BorderSurface is exactly the building block for that: a Rectangle
      // with borderSpec, radius and separate paddings. The model is
      // network/Panel.qml:1891ff (statusMsgWrapper), which works with the
      // same two lines:
      //     color:      Style.normalFillFor(<foreground>)
      //     borderSpec: Border.controlSpec("normal", <foreground>, Color.accent)
      // Both values are derived from root.fg -- NO fixed color stands
      // here, the field follows a theme change like every first-party
      // panel.
      //
      // IMPORTANT for the four promises: visibility does NOT change. The
      // frame carries exactly the same condition as addColumn, and
      // addColumn keeps its own explicitly (duplicated, but word for word
      // -- so a reader sees at once that the condition stayed the same).
      // Unchanged, therefore:
      //  * The error display AT THE END of addColumn is effective only when
      //    root.addOpen === true, the catch-all further up only when
      //    root.addOpen === false -- provably disjoint, nothing doubled,
      //    nothing lost.
      //  * Errors of the remove path still sit in confirmColumn at the row
      //    concerned, not in here.
      BorderSurface {
        id: addFrame
        visible: root.addOpen
        width: panelColumn.width
        implicitHeight: addColumn.implicitHeight
                        + addFrame.contentTopInset + addFrame.contentBottomInset
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.fg)
        borderSpec: Border.controlSpec("normal", root.fg, Color.accent)
        padding: Style.spacing.sm

      Column {
        id: addColumn
        visible: root.addOpen
        x: addFrame.contentLeftInset
        y: addFrame.contentTopInset
        width: addFrame.width - addFrame.contentLeftInset - addFrame.contentRightInset
        spacing: Style.space(6)

        // Says what happens in this box. The same building block and the
        // same spelling as the heading "VPN" at the very top and as
        // "POWER PROFILE" in the power panel.
        PanelSectionHeader {
          text: "ADD CONNECTION"
          foreground: root.fg
          fontFamily: root.fontFam
        }

        Button {
          id: chooseButton
          width: addColumn.width
          text: root.addBusy ? "Please wait ..."
                : root.addBrowsing ? "Close the picker"
                : root.addPath === "" ? "Choose a file ..."
                : "Choose another file ..."
          // Unchanged, the same lock as before on the MouseArea; with
          // `enabled` on the parent QML disables the MouseArea inside the
          // button along with it. The opacity next to it is pure display.
          enabled: !root.addBusy
          opacity: chooseButton.enabled ? 1.0 : 0.45
          foreground: root.fg
          fontFamily: root.fontFam
          bordered: true
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          onClicked: root.toggleBrowser()
        }

        // The file list -- entirely inside this panel, see folderModel. It
        // rides along in the existing ScrollView but bounds its own height
        // (fileList.height): a folder with a hundred entries should not
        // stretch the panel apart but scroll within the list.
        Column {
          id: browseColumn
          visible: root.addBrowsing
          width: addColumn.width
          spacing: Style.space(4)

          // Where we currently are. ElideMiddle instead of wrapping: the
          // start and the end of a path both say something, the middle
          // rarely does.
          Text {
            width: browseColumn.width
            text: "Folder: " + root.browseDir
            color: root.fg
            opacity: 0.7
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          // One level up. Only absent in "/" -- there is nothing above
          // that. Deliberately placed ABOVE the list and outside it: that
          // way the way out stays visible even when the folder is empty or
          // unreadable.
          Rectangle {
            visible: root.parentDir(root.browseDir) !== ""
            width: browseColumn.width
            height: Style.spacing.popupRowHeight
            radius: Style.cornerRadius
            color: upMouse.containsMouse ? Style.hoverFill : "transparent"

            Text {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.spacing.sm
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              text: root.glyphUp + "  One level up"
              color: root.fg
              font.family: root.fontFam
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            MouseArea {
              id: upMouse
              anchors.fill: parent
              hoverEnabled: !root.addBusy
              enabled: !root.addBusy
              cursorShape: Qt.PointingHandCursor
              onClicked: root.browseDir = root.parentDir(root.browseDir)
            }
          }

          ListView {
            id: fileList
            width: browseColumn.width
            // Bound first, then scroll. contentHeight depends only on the
            // delegates (fixed row height), not on this height -- hence no
            // binding loop.
            height: Math.min(contentHeight, Style.space(200))
            visible: folderModel.count > 0
            clip: true
            model: folderModel
            boundsBehavior: Flickable.StopAtBounds
            // If everything fits, the list does not swallow the mouse
            // wheel -- then the panel's ScrollView keeps scrolling.
            interactive: contentHeight > height

            delegate: Rectangle {
              id: entry
              // The roles of FolderListModel as named properties.
              // "required" resolves them unambiguously in the delegate;
              // filePath is a finished filesystem path, exactly what
              // addPath and bin/omarchy-vpn-add expect.
              required property string fileName
              required property string filePath
              required property bool fileIsDir

              width: fileList.width
              height: Style.spacing.popupRowHeight
              radius: Style.cornerRadius
              color: entryMouse.containsMouse ? Style.hoverFill : "transparent"

              Text {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.spacing.sm
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                text: (entry.fileIsDir ? root.glyphFolder : root.glyphFile) + "  " + entry.fileName
                color: root.fg
                font.family: root.fontFam
                font.pixelSize: Style.font.body
                elide: Text.ElideMiddle
              }

              MouseArea {
                id: entryMouse
                anchors.fill: parent
                hoverEnabled: !root.addBusy
                enabled: !root.addBusy
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (entry.fileIsDir) root.browseDir = entry.filePath
                  else root.pickFile(entry.filePath)
                }
              }
            }
          }

          Text {
            width: browseColumn.width
            visible: folderModel.status === FolderListModel.Loading
            text: "Reading ..."
            color: root.fg
            opacity: 0.7
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
          }

          // No mute empty state: whoever lands in an empty or locked
          // folder should be able to read why nothing is there -- the way
          // out stands above it. Disjoint from the loading display
          // (status).
          Text {
            width: browseColumn.width
            visible: folderModel.count === 0 && folderModel.status !== FolderListModel.Loading
            text: "There is nothing to pick here -- neither a subfolder nor an *.ovpn or *.conf file. It is also possible that the folder is not readable."
            color: root.fg
            opacity: 0.7
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // The chosen path -- only while the check is still outstanding or
        // the file was rejected (addKind === ""): then it is the only clue
        // by which the user can tell WHICH file caused the error directly
        // below. As soon as the summary appears (addKind !== "") the path
        // line disappears again -- the remote and "certificates embedded"
        // already say whether it is the right file, and the line saves
        // height in the panel (see the report). The path is not a secret;
        // the CONTENT appears nowhere, see the header comment of
        // inspectProc.
        Text {
          width: addColumn.width
          visible: root.addPath !== "" && root.addKind === ""
          text: "File: " + root.addPath
          color: root.fg
          opacity: 0.7
          font.family: root.fontFam
          font.pixelSize: Style.font.caption
          wrapMode: Text.WrapAnywhere
        }

        // The summary of the verdict only -- the content of the
        // configuration appears nowhere here, see the header comment of
        // inspectProc.
        Text {
          width: addColumn.width
          visible: root.addKind !== ""
          text: "Kind: " + (root.addKind === "wireguard" ? "WireGuard" : "OpenVPN")
                + "\nRemote: " + root.addRemote
                + (root.addKind === "openvpn"
                   ? "\nCertificates embedded: " + (root.addEmbedded ? "yes" : "no")
                   : "")
                + "\nSize: " + root.addBytes + (root.addBytes === 1 ? " byte" : " bytes")
          color: root.fg
          opacity: 0.85
          font.family: root.fontFam
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // text: root.addLabel binds only ONCE: as soon as the user types,
        // TextInput sets text directly and the declarative binding is gone
        // (standard QML behavior, the same pattern as mullvadQuery in the
        // tailscale panel). That is why the field is additionally cleared
        // by hand via its id at the two reset places above (Cancel,
        // successful create) -- otherwise the old label would still be
        // visible on the next open even though root.addLabel is already
        // "".
        TextField {
          id: labelField
          width: addColumn.width
          visible: root.addKind !== ""
          placeholderText: "Label"
          text: root.addLabel
          foreground: root.fg
          onTextChanged: root.addLabel = text
        }

        TextField {
          id: groupField
          width: addColumn.width
          visible: root.addKind !== ""
          placeholderText: "Group (optional)"
          text: root.addGroup
          foreground: root.fg
          onTextChanged: root.addGroup = text
        }

        // Preview -- bin/omarchy-vpn-add is authoritative, see
        // root.derivedName() and the report on this task.
        Text {
          width: addColumn.width
          visible: root.addKind !== ""
          text: "Unit: " + root.addUnit
          color: root.fg
          opacity: 0.7
          font.family: root.fontFam
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // The close of the operation -- and the button the user did not
        // find on their first attempt. That is why it alone additionally
        // carries `active` here: with it Button fills its surface with
        // Style.selectedFillFor(...) and stands out from the
        // border-without-fill of the other buttons. That too is a derived
        // color -- Button takes it from foreground and Color.accent, no
        // color value stands here.
        //
        // Visibility and lock are unchanged: visible only once the check
        // has reported a usable file (addKind !== ""), locked as long as an
        // operation is running.
        Button {
          id: createButton
          width: addColumn.width
          visible: root.addKind !== ""
          text: root.addBusy ? "Please wait ..." : "Create"
          enabled: !root.addBusy
          opacity: createButton.enabled ? 1.0 : 0.45
          foreground: root.fg
          fontFamily: root.fontFam
          bordered: true
          active: true
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          onClicked: root.createConnection()
        }

        Text {
          width: addColumn.width
          visible: root.addError !== ""
          text: root.addError
          color: root.fg
          font.family: root.fontFam
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
      }

      // Footer. Deliberately the last thing in the column and dimmed: it
      // is meant to be findable when someone reports a problem, not to
      // compete with the connection list.
      PanelSeparator {
        foreground: root.fg
      }

      Text {
        width: panelColumn.width
        horizontalAlignment: Text.AlignRight
        text: "v" + root.pluginVersion
        color: root.fg
        opacity: 0.55
        font.family: root.fontFam
        font.pixelSize: Style.font.caption
      }
    }
    }
  }
}
