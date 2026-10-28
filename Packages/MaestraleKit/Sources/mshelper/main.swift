import Darwin
import MaestraleCore

// Privileged helper: runs as root, launched by AdminRunner after the password
// prompt. It only removes or moves items inside `SystemRoots`, with the
// symlink-safe operations of `PinnedFileSystem`. See `AdminHelper` for usage.
let result = AdminHelper.run(Array(CommandLine.arguments.dropFirst()), roots: SystemRoots.paths)
for line in result.lines {
    print(line)
    if result.status != 0 { fputs(line + "\n", stderr) }
}
exit(result.status)
