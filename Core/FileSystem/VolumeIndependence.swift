import Foundation

/// Independence of copies is a property of physical devices, not of mounted
/// volumes. Two volumes are shared, independent, or unknown (a device the
/// platform could not name), and unknown is never treated as independent.
public extension FileSystemVolume {
    /// Proven to share a failure domain: the same mounted volume, or two
    /// volumes on one physical device.
    func sharesPhysicalDevice(with other: FileSystemVolume) -> Bool {
        if identifier == other.identifier { return true }
        guard let mine = physicalDeviceIdentifier,
              let theirs = other.physicalDeviceIdentifier else { return false }
        return mine == theirs
    }
}
