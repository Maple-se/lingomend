import AppKit

public enum ClipboardRestoration: Equatable, Sendable { case restored, changedExternally, failed }

/// Scoped to one explicit acceptance. No observation, disk storage or provider access.
@MainActor
public final class NativeClipboardLease {
  private let board: NSPasteboard
  private static let markerType = NSPasteboard.PasteboardType(
    "com.maplese.lingomend.acceptance-token")
  private var saved: [[NSPasteboard.PasteboardType: Data]]?
  private var token: Data?
  private var ownedChangeCount: Int?

  public init(board: NSPasteboard = .general) { self.board = board }

  public var ownsContents: Bool {
    guard let token, let ownedChangeCount else { return false }
    return board.changeCount == ownedChangeCount && board.data(forType: Self.markerType) == token
  }

  public func begin(rtf: Data, text: String) throws {
    guard saved == nil else { throw NativePasteError.busy }
    let count = board.changeCount
    let items = board.pasteboardItems ?? []
    guard items.count <= 32, !items.isEmpty || (board.types ?? []).isEmpty else {
      throw NativePasteError.clipboardUnavailable
    }
    var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
    var total = 0
    for item in items {
      guard item.types.count <= 64, !item.types.isEmpty else {
        throw NativePasteError.clipboardUnavailable
      }
      var contents: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        // File promises/providers cannot be recreated faithfully with raw bytes.
        guard !type.rawValue.lowercased().contains("promise"),
          let data = item.data(forType: type), data.count <= 4_194_304 - total
        else {
          throw NativePasteError.clipboardUnavailable
        }
        total += data.count
        contents[type] = data
      }
      snapshot.append(contents)
    }
    guard board.changeCount == count else { throw NativePasteError.clipboardChanged }
    let token = Data(UUID().uuidString.utf8)
    let item = NSPasteboardItem()
    guard item.setData(rtf, forType: .rtf), item.setString(text, forType: .string),
      item.setData(token, forType: Self.markerType)
    else { throw NativePasteError.clipboardUnavailable }
    saved = snapshot
    self.token = token
    board.clearContents()
    ownedChangeCount = board.changeCount
    guard board.writeObjects([item]) else {
      // Restore only the still-empty board that we cleared, not another app's copy.
      if restoreAfterFailedWrite() == .failed {
        throw NativePasteError.clipboardRestorationFailed(dispatched: false)
      }
      throw NativePasteError.clipboardUnavailable
    }
    ownedChangeCount = board.changeCount
    guard ownsContents else {
      restore()
      throw NativePasteError.clipboardChanged
    }
  }

  @discardableResult public func restore() -> ClipboardRestoration {
    guard let saved else { return .restored }
    defer {
      self.saved = nil
      token = nil
      ownedChangeCount = nil
    }
    guard ownsContents else { return .changedExternally }
    return writeSnapshot(saved)
  }

  private func restoreAfterFailedWrite() -> ClipboardRestoration {
    guard let saved, board.changeCount == ownedChangeCount else {
      self.saved = nil
      token = nil
      ownedChangeCount = nil
      return .changedExternally
    }
    let result = writeSnapshot(saved)
    self.saved = nil
    token = nil
    ownedChangeCount = nil
    return result
  }

  private func writeSnapshot(_ snapshot: [[NSPasteboard.PasteboardType: Data]])
    -> ClipboardRestoration
  {
    let items = snapshot.map { contents in
      let item = NSPasteboardItem()
      for (type, data) in contents { _ = item.setData(data, forType: type) }
      return item
    }
    // NSPasteboard has no atomic compare-and-swap. Ownership is checked just before
    // this synchronous restore; concurrent writers still require user acceptance tests.
    board.clearContents()
    return items.isEmpty || board.writeObjects(items) ? .restored : .failed
  }
}
