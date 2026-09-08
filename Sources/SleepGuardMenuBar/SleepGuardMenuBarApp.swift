import AppKit
import SleepGuardCore
import SwiftUI

/// Menu-bar surface for the sleep-blocker inspector.
///
/// ## What this app does and does not do
///
/// It reads four documented sources of power-assertion state and explains why
/// the Mac is awake. It is strictly read-only: it never releases an assertion,
/// signals or terminates a process, elevates privilege, writes to the registry,
/// makes any network request, or collects telemetry. There is no account, no
/// preferences file and no persistence of any kind.
///
/// Rows carry a synthetic per-scan identity, never a live handle. Because this
/// build takes no actions, there is no action path that could target a stale
/// PID; if one is ever added it must re-resolve and compare identity first.
@main
struct SleepGuardMenuBarApp: App {
  @StateObject private var model = ScanViewModel()

  var body: some Scene {
    MenuBarExtra("SleepGuard", systemImage: "moon.zzz") {
      ScanView(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}

/// Observable wrapper around the deterministic `ScanPresenter`.
///
/// All decision logic lives in `ScanPresenter` (in `SleepGuardCore`, fully unit
/// tested); this class only moves work off the main actor and republishes the
/// result on it. The generation token from `beginScan()` is what makes a
/// refresh during an in-flight scan harmless: a superseded completion is
/// discarded rather than published.
@MainActor
final class ScanViewModel: ObservableObject {
  private let presenter = ScanPresenter()
  private let source: SleepScanSource

  @Published private(set) var rows: [BlockerRow] = []
  @Published private(set) var notice: String?
  @Published private(set) var lastScanDate: Date?
  @Published private(set) var isScanning = false

  init(source: SleepScanSource = LiveSleepScanSource()) {
    self.source = source
  }

  func refresh() {
    let token = presenter.beginScan()
    syncFromPresenter()
    let runner = SleepScanRunner(source: source)
    Task.detached(priority: .userInitiated) { [weak self] in
      let outcome = runner.scan()
      await MainActor.run { [weak self] in
        guard let self else { return }
        // publish() itself rejects a superseded token; the return value is
        // ignored because a discarded stale completion must change nothing.
        _ = self.presenter.publish(outcome, token: token)
        self.syncFromPresenter()
      }
    }
  }

  private func syncFromPresenter() {
    rows = presenter.rows
    notice = presenter.notice
    lastScanDate = presenter.lastScanDate
    isScanning = presenter.isScanning
  }
}

struct ScanView: View {
  @ObservedObject var model: ScanViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Sleep blockers").font(.headline)
        Spacer()
        Button("Rescan") { model.refresh() }
          .disabled(model.isScanning)
      }

      // The terminal notice is rendered BEFORE any row detail and does not
      // depend on a selected row. A scan can legitimately end with zero rows,
      // and "nothing found blocking sleep" must still be visible.
      if model.isScanning {
        Text("Scanning…").foregroundStyle(.secondary)
      } else if let notice = model.notice {
        VStack(alignment: .leading, spacing: 2) {
          Text(notice).font(.subheadline)
          // Power-assertion state changes second to second, so a redisplayed
          // result must show when it was actually observed.
          if let scanned = model.lastScanDate {
            Text("as of \(Self.timeFormatter.string(from: scanned))")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
      } else {
        Text("No scan has run yet.").foregroundStyle(.secondary)
      }

      if !model.rows.isEmpty {
        Divider()
        ForEach(model.rows) { row in
          VStack(alignment: .leading, spacing: 2) {
            Text("\(row.title) (pid \(row.pid))").font(.system(.body, design: .monospaced))
            Text(row.detail).font(.caption).foregroundStyle(.secondary)
            Text(Self.subtitle(for: row)).font(.caption2).foregroundStyle(.secondary)
          }
        }
      }

      Divider()
      Button("Quit") { NSApplication.shared.terminate(nil) }
    }
    .padding(12)
    .frame(width: 380)
    .onAppear { if model.notice == nil { model.refresh() } }
  }

  /// Unknown duration is rendered as unknown, never as `0s`.
  static func subtitle(for row: BlockerRow) -> String {
    guard let held = row.heldSeconds else {
      return "\(row.rawType) · duration unknown"
    }
    return "\(row.rawType) · held \(held)s"
  }

  static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return formatter
  }()
}
