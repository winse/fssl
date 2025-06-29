import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:fssl/dedup_isolate.dart';
import 'package:path/path.dart';
import 'package:win32/win32.dart' as win32; // 用于调用 SHFileOperation 放入回收站

typedef CreateHardLinkFunc =
    Int32 Function(
      Pointer<Utf16> lpFileName,
      Pointer<Utf16> lpExistingFileName,
      Pointer<Void> lpSecurityAttributes,
    );

typedef CreateHardLink =
    int Function(
      Pointer<Utf16> lpFileName,
      Pointer<Utf16> lpExistingFileName,
      Pointer<Void> lpSecurityAttributes,
    );

extension GroupList on List<File> {
  File get groupTarget => this.first;

  List<File> get groupSourceFiles => this.sublist(1);
}

typedef ProgressCallback = void Function(int value, int total, String msg);

class DedupController {
  Future<Map<String, List<File>>> computeHashesWithScan(Directory dir, [ProgressCallback? callback]) async {
    Map<String, List<File>> hashedFileMap = {};

    var files =
        await dir.list(recursive: true, followLinks: false).where((e) => e is File).cast<File>().toList();
    files.sort((a, b) => basenameWithoutExtension(a.path).compareTo(basenameWithoutExtension(b.path)));

    final total = files.length;

    for (var i = 0; i < files.length; i++) {
      var file = files[i];

      String hash = await sha256OfFile(file);
      hashedFileMap.putIfAbsent(hash, () => []).add(file);

      callback?.call(i + 1, total, file.path);
    }

    hashedFileMap.forEach((key, group) {
      final target = group.groupTarget;
      final sourceFiles = group.groupSourceFiles;
      for (int i = sourceFiles.length - 1; i >= 0; i--) {
        final sourceFile = sourceFiles[i];
        if (isSameFileid(target, sourceFile)) {
          group.remove(sourceFile);
        }
      }
    });

    return {
      for (var e in hashedFileMap.entries)
        if (e.value.length > 1) e.key: e.value,
    };
  }

  Future<String> sha256OfFile(File file) async {
    var bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  Future<void> performDedups(
    List<String> groups,
    Map<String, List<File>> duplicateGroups,
    void Function(int, int, DedupResponse) progress,
  ) async {
    DedupIsolateManager manager = DedupIsolateManager();
    await manager.start();

    final total = groups.length;
    int handled = 0;
    for (int i = 0; i < total; i++) {
      var group = groups[i];

      var files = duplicateGroups[group]!;
      var original = files.groupTarget;

      for (var duplicate in files.groupSourceFiles) {
        final resp = await manager.dedup(duplicate, original);
        progress(handled, total, resp);
      }
    }
    await manager.dedupDone();
  }

  bool performDedup(File duplicate, File original) {
    // duplicate.deleteSync();
    // 确保删除
    while (duplicate.existsSync()) {
      moveToRecycleBin(duplicate.path); // 使用回收站
    }

    bool ok = createHardLink(duplicate.path, original.path);
    return ok;
  }

  void moveToRecycleBin(String path) {
    final pForm = path.toNativeUtf16();
    final op =
        calloc<win32.SHFILEOPSTRUCT>()
          ..ref.wFunc = win32.FO_DELETE
          ..ref.pFrom = pForm
          ..ref.fFlags = win32.OFN_ALLOWMULTISELECT | win32.FOF_ALLOWUNDO | win32.FOF_NOCONFIRMATION;

    try {
      win32.SHFileOperation(op);
    } finally {
      calloc.free(pForm);
      calloc.free(op);
    }
  }

  final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  bool createHardLink(String linkPath, String existingFilePath) {
    final link = linkPath.toNativeUtf16();
    final target = existingFilePath.toNativeUtf16();

    try {
      // win32.CreateHardLink
      final createHardLinkPtr = _kernel32.lookupFunction<CreateHardLinkFunc, CreateHardLink>(
        'CreateHardLinkW',
      );
      final result = createHardLinkPtr(link, target, nullptr) != 0;
      // 不能用软连接。软连接就得确定一个根！
      // final result = win32.CreateSymbolicLink(link, target, 0); // 0x0 表示是文件符号链接

      return result != 0;
    } finally {
      calloc.free(link);
      calloc.free(target);
    }
  }

  bool isSameFileid(File f1, File f2) {
    Map<String, int>? _getFileInfo(String path) {
      final lpFileName = path.toNativeUtf16();
      final hFile = win32.CreateFile(
        lpFileName,
        0,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
        nullptr,
        win32.OPEN_EXISTING,
        win32.FILE_FLAG_BACKUP_SEMANTICS,
        0,
      );
      calloc.free(lpFileName);

      if (hFile == win32.INVALID_HANDLE_VALUE) {
        return null;
      }

      final info = calloc<win32.BY_HANDLE_FILE_INFORMATION>();

      try {
        final success = win32.GetFileInformationByHandle(hFile, info) != 0;

        Map<String, int>? result;
        if (success) {
          result = {
            'volume': info.ref.dwVolumeSerialNumber,
            'indexHigh': info.ref.nFileIndexHigh,
            'indexLow': info.ref.nFileIndexLow,
          };
        }

        return result;
      } finally {
        calloc.free(info);
        win32.CloseHandle(hFile);
      }
    }

    final info1 = _getFileInfo(f1.path);
    final info2 = _getFileInfo(f2.path);

    if (info1 == null || info2 == null) return false;
    // 组合 FileIndexHigh 和 FileIndexLow 作为唯一标识
    // return (fileInfo.ref.FileIndexHigh << 32) + fileInfo.ref.FileIndexLow;
    return info1['volume'] == info2['volume'] &&
        info1['indexHigh'] == info2['indexHigh'] &&
        info1['indexLow'] == info2['indexLow'];
  }
}
