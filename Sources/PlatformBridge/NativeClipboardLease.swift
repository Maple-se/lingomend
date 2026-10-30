import AppKit
import DiagnosticsCore

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
  public private(set) var rejection: ClipboardDiagnostic?

  public init(board: NSPasteboard = .general) { self.board = board }

  public var ownsContents: Bool {
    guard let token, let ownedChangeCount else { return false }
    return board.changeCount == ownedChangeCount && board.data(forType: Self.markerType) == token
  }

  public func begin(rtf: Data? = nil, text: String) throws {
    guard saved == nil else { throw NativePasteError.busy }
    rejection = nil
    let count = board.changeCount
    guard let items = board.pasteboardItems else { throw reject(.itemsUnavailable, items: 0) }
    guard items.count <= 32 else {
      throw reject(.itemLimit, items: items.count)
    }
    guard !items.isEmpty || (board.types ?? []).isEmpty else {
      throw reject(.itemsUnavailable, items: items.count)
    }
    var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
    var total = 0
    for item in items {
      guard !item.types.isEmpty else {
        throw reject(.emptyTypes, items: items.count, bytes: total)
      }
      guard item.types.count <= 64 else {
        throw reject(.typeLimit, items: items.count, types: item.types.count, bytes: total)
      }
      var contents: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        // File promises/providers cannot be recreated faithfully with raw bytes.
        guard !type.rawValue.lowercased().contains("promise") else {
          throw reject(.promisedData, items: items.count, types: item.types.count, bytes: total)
        }
        guard let data = item.data(forType: type) else {
          throw reject(.dataUnavailable, items: items.count, types: item.types.count, bytes: total)
        }
        guard data.count <= 4_194_304 - total else {
          throw reject(.byteLimit, items: items.count, types: item.types.count, bytes: 4_194_305)
        }
        total += data.count
        contents[type] = data
      }
      snapshot.append(contents)
    }
    guard board.changeCount == count else { throw NativePasteError.clipboardChanged }
    let token = Data(UUID().uuidString.utf8)
    let item = NSPasteboardItem()
    guard (rtf == nil || item.setData(rtf!, forType: .rtf)), item.setString(text, forType: .string),
      item.setData(token, forType: Self.markerType)
    else { throw reject(.payloadUnavailable, items: items.count, bytes: total) }
    saved = snapshot
    self.token = token
    board.clearContents()
    ownedChangeCount = board.changeCount
    guard board.writeObjects([item]) else {
      let failure = reject(.writeFailed, items: items.count, bytes: total)
      // Restore only the still-empty board that we cleared, not another app's copy.
      if restoreAfterFailedWrite() == .failed {
        throw NativePasteError.clipboardRestorationFailed(dispatched: false)
      }
      throw failure
    }
    ownedChangeCount = board.changeCount
    guard ownsContents else {
      restore()
      throw NativePasteError.clipboardChanged
    }
  }

  private func reject(_ reason: ClipboardDiagnostic.Reason, items: Int, types: Int = 0,
                      bytes: Int = 0) -> NativePasteError {
    rejection = ClipboardDiagnostic(reason: reason, items: items, types: types, bytes: bytes)
    return .clipboardUnavailable
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
