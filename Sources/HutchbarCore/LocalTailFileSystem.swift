// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

public struct LocalTailFileSystem: TailFileSystem {
  public init() {}

  public func openRegularFile(at path: String) throws -> any TailFile {
    guard !path.isEmpty, !path.utf8.contains(0) else { throw TailError.unsafeFile }
    let components = path.split(separator: "/").map(String.init)
    guard !components.isEmpty, !components.contains("..") else { throw TailError.unsafeFile }
    var directory = Darwin.open(path.hasPrefix("/") ? "/" : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directory >= 0 else { throw TailError.unavailable }
    defer { Darwin.close(directory) }
    for component in components.dropLast() {
      let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw TailError.unsafeFile }
      Darwin.close(directory)
      directory = next
    }
    guard let name = components.last else { throw TailError.unsafeFile }
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ELOOP { throw TailError.unsafeFile }
      throw TailError.unavailable
    }
    let file = LocalTailFile(descriptor: descriptor)
    do {
      _ = try file.snapshot()
      return file
    } catch {
      file.close()
      throw TailError.unsafeFile
    }
  }
}

private final class LocalTailFile: TailFile {
  private var descriptor: Int32

  init(descriptor: Int32) { self.descriptor = descriptor }
  deinit { close() }

  func snapshot() throws -> FileSnapshot {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw TailError.ioFailure }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw TailError.unsafeFile }
    return FileSnapshot(
      device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino,
      size: UInt64(info.st_size))
  }

  func read(from offset: UInt64, count: Int) throws -> Data {
    guard offset <= UInt64(Int64.max) else { throw TailError.ioFailure }
    var data = Data(count: count)
    let received = data.withUnsafeMutableBytes { buffer in
      pread(descriptor, buffer.baseAddress, count, off_t(offset))
    }
    guard received >= 0 else { throw TailError.ioFailure }
    data.count = received
    return data
  }

  func close() {
    if descriptor >= 0 {
      Darwin.close(descriptor)
      descriptor = -1
    }
  }
}
