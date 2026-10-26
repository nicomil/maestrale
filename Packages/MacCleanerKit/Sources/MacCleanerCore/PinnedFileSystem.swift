import Darwin
import Foundation

/// The system folders where administrator operations may remove or move items.
/// Paths are canonical (no symlinks): "/private/var/log", not "/var/log".
public enum SystemRoots {
    public static let paths: [String] = [
        "/Library/Caches", "/Library/Logs", "/private/var/log", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools", "/Library/Application Support", "/Library/Preferences",
        "/Library/Audio/Plug-Ins", "/Library/Internet Plug-Ins", "/Library/PreferencePanes",
        "/Library/Screen Savers", "/Library/QuickLook", "/Library/Spotlight", "/Applications", "/Users/Deleted Users",
    ]
}

public struct PinnedFileError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }

    static func posix(_ what: String, _ code: Int32 = errno) -> PinnedFileError {
        PinnedFileError("\(what): \(String(cString: strerror(code)))")
    }
}

/// File operations that never follow a symlink and never look a path up twice.
///
/// A folder is opened one component at a time from "/", refusing symlinks at
/// every step; everything after that works relative to the open folder. If
/// someone swaps a folder on the way for a symlink, opening fails instead of
/// leading somewhere else, and once a folder is open, later swaps of its path
/// no longer matter. This is what the privileged helper uses.
public enum PinnedFileSystem {
    /// Opens an absolute, canonical folder path without following symlinks.
    /// The caller closes the returned descriptor.
    public static func openDirectory(_ path: String) throws -> Int32 {
        let components = try canonicalComponents(path)
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw PinnedFileError.posix("/") }
        for component in components {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(fd)
            guard next >= 0 else {
                if code == ELOOP || code == ENOTDIR {
                    throw PinnedFileError("\(path): la cartella è cambiata dopo il controllo")
                }
                throw PinnedFileError.posix(path, code)
            }
            fd = next
        }
        return fd
    }

    /// Splits "/a/b/c" into ["a", "b", "c"], refusing anything that is not a
    /// plain absolute path ("//", ".", "..", relative paths).
    static func canonicalComponents(_ path: String) throws -> [String] {
        guard path.hasPrefix("/") else { throw PinnedFileError("\(path): percorso non assoluto") }
        if path == "/" { return [] }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy(isPlainName) else { throw PinnedFileError("\(path): percorso non valido") }
        return components
    }

    /// A single path component: not empty, no "/", not "." or "..". Tabs and
    /// line breaks are refused too, since the helper reports one item per line.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains(where: { $0 == "/" || $0 == "\0" || $0 == "\t" || $0 == "\n" || $0 == "\r" })
    }

    /// Information about an entry of an open folder, without following symlinks.
    public static func entryInfo(_ dir: Int32, _ name: String) throws -> stat {
        var info = stat()
        guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw PinnedFileError.posix(name) }
        return info
    }

    /// Deletes an entry of an open folder. A symlink is removed itself, never
    /// its target; a folder is emptied from the inside without leaving the
    /// volume it is on.
    public static func removeEntry(in dir: Int32, named name: String) throws {
        guard isPlainName(name) else { throw PinnedFileError("\(name): nome non valido") }
        let info = try entryInfo(dir, name)
        guard info.st_mode & S_IFMT == S_IFDIR else {
            guard unlinkat(dir, name, 0) == 0 else { throw PinnedFileError.posix(name) }
            return
        }
        let child = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw PinnedFileError.posix(name) }
        defer { close(child) }
        var opened = stat()
        guard fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            throw PinnedFileError("\(name): è cambiato durante la rimozione")
        }
        var parent = stat()
        guard fstat(dir, &parent) == 0, parent.st_dev == info.st_dev else {
            throw PinnedFileError("\(name): è su un altro volume")
        }
        for entry in try names(in: child) {
            try removeEntry(in: child, named: entry)
        }
        guard unlinkat(dir, name, AT_REMOVEDIR) == 0 else { throw PinnedFileError.posix(name) }
    }

    /// The entries of an open folder, without "." and "..".
    static func names(in dir: Int32) throws -> [String] {
        let copy = dup(dir)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw PinnedFileError.posix("lettura della cartella")
        }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }

    /// Moves an entry of one open folder into another under a name that is not
    /// taken: "name", then "name 2", "name 3"… An existing item is never replaced.
    /// Returns the name used.
    @discardableResult
    public static func moveEntry(from source: Int32, named name: String, into destination: Int32) throws -> String {
        guard isPlainName(name) else { throw PinnedFileError("\(name): nome non valido") }
        for attempt in 1...1000 {
            let target = numberedName(name, attempt)
            if renameatx_np(source, name, destination, target, UInt32(RENAME_EXCL)) == 0 { return target }
            guard errno == EEXIST else { throw PinnedFileError.posix(name) }
        }
        throw PinnedFileError("\(name): troppi elementi con lo stesso nome nel Cestino")
    }

    /// "report.pdf" → "report.pdf", "report 2.pdf", "report 3.pdf"…
    public static func numberedName(_ name: String, _ number: Int) -> String {
        guard number > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty || stem.isEmpty ? "\(name) \(number)" : "\(stem) \(number).\(ext)"
    }

    /// True for items protected by System Integrity Protection.
    public static func isRestricted(_ info: stat) -> Bool {
        info.st_flags & 0x0008_0000 != 0 // SF_RESTRICTED
    }
}

/// The privileged helper's work, kept here so it can be tested without root.
///
///     mchelper remove <folder> <name> [<folder> <name> ...]
///     mchelper trash <trash folder> <owner uid> <folder> <name> [<folder> <name> ...]
///
/// Folders must be canonical paths inside `roots`. Each item gets one line on
/// standard output: "ok<TAB>path[<TAB>new path]" or "err<TAB>path<TAB>reason".
public enum AdminHelper {
    public struct Result: Sendable {
        public var lines: [String] = []
        /// 0 when every item was handled (even if some failed), 2 for bad usage.
        public var status: Int32 = 0
    }

    public static func run(_ arguments: [String], roots: [String]) -> Result {
        var result = Result()
        guard let command = arguments.first else { return usage() }
        var rest = Array(arguments.dropFirst())
        var trash: (fd: Int32, path: String)?
        switch command {
        case "remove":
            break
        case "trash":
            guard rest.count >= 2, let owner = uid_t(rest[1]) else { return usage() }
            let path = rest[0]
            rest.removeFirst(2)
            do {
                let fd = try PinnedFileSystem.openDirectory(path)
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_uid == owner else {
                    close(fd)
                    throw PinnedFileError("\(path): il Cestino non appartiene all'utente")
                }
                trash = (fd, path)
            } catch {
                return Result(lines: ["err\t\(path)\t\(error)"], status: 1)
            }
        default:
            return usage()
        }
        defer { if let trash { close(trash.fd) } }
        guard !rest.isEmpty, rest.count % 2 == 0 else { return usage() }

        for index in stride(from: 0, to: rest.count, by: 2) {
            let folder = rest[index], name = rest[index + 1]
            let path = folder == "/" ? "/\(name)" : "\(folder)/\(name)"
            do {
                try checkAllowed(folder: folder, name: name, roots: roots)
                let dir = try PinnedFileSystem.openDirectory(folder)
                defer { close(dir) }
                let info = try PinnedFileSystem.entryInfo(dir, name)
                guard !PinnedFileSystem.isRestricted(info) else { throw PinnedFileError("\(path): protetto da SIP") }
                if let trash {
                    let used = try PinnedFileSystem.moveEntry(from: dir, named: name, into: trash.fd)
                    result.lines.append("ok\t\(path)\t\(trash.path)/\(used)")
                } else {
                    try PinnedFileSystem.removeEntry(in: dir, named: name)
                    result.lines.append("ok\t\(path)")
                }
            } catch {
                result.lines.append("err\t\(path)\t\(error)")
            }
        }
        return result
    }

    /// The item must be strictly inside one of the roots, named plainly.
    static func checkAllowed(folder: String, name: String, roots: [String]) throws {
        guard PinnedFileSystem.isPlainName(name), (try? PinnedFileSystem.canonicalComponents(folder)) != nil,
              roots.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) else {
            throw PinnedFileError("\(folder)/\(name): fuori dalle cartelle consentite")
        }
    }

    static func usage() -> Result {
        Result(lines: ["err\t-\tuso: mchelper remove|trash …"], status: 2)
    }
}
