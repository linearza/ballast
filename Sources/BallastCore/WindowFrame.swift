import CoreGraphics

/// The frame a window should take when its content becomes `contentHeight` tall, with the top edge held still.
/// A menu bar window hangs from the menu bar, so growing or shrinking must move the bottom, not the top.
/// Returns nil when there is nothing to do: a change under 1 pt, or a height that makes no sense.
public func topAnchoredFrame(_ old: CGRect, contentHeight: CGFloat) -> CGRect? {
    guard contentHeight.isFinite, contentHeight > 0, abs(contentHeight - old.height) >= 1 else { return nil }
    return CGRect(x: old.minX, y: old.maxY - contentHeight, width: old.width, height: contentHeight)
}
