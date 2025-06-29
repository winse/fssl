import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart';
import 'package:win32/win32.dart' as win32; // 用于调用 SHFileOperation 放入回收站

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FSSL - File Space Saving Linking',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo), useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? selectedDir;

  Map<String, List<File>> duplicateGroups = {};
  Set<String> selected = {};

  List<File> allFiles = [];
  int total = 0;
  int handled = 0;
  String _currentState = '';
  double progress = 0;

  bool _stageFinished = false;
  bool _forceDelete = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FSSL - Link your clones, save your space')),
      body: Column(
        children: [
          Container(
            color: Colors.blue.shade50,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(child: Text(selectedDir ?? '请选择一个目录')),
                ElevatedButton(onPressed: selectDirectory, child: const Text('选择目录')),
              ],
            ),
          ),
          if (total > 0)
            Container(
              color: Colors.green.shade50,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('文件: $handled / $total'),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 4),
                  Text(
                    _currentState,
                    softWrap: true,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Container(
              color: Colors.orange.shade50,
              child: ListView(
                children:
                    duplicateGroups.entries.map((entry) {
                      String hash = entry.key;

                      List<File> files = entry.value;
                      File targetFile = files.groupTarget;
                      List<File> sourceFiles = files.groupSourceFiles;
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Checkbox(
                                value: selected.contains(hash),
                                onChanged: (checked) {
                                  setState(() {
                                    if (checked == true) {
                                      selected.add(hash);
                                    } else {
                                      selected.remove(hash);
                                    }
                                  });
                                },
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    InkWell(
                                      onTap: () => openFileInExplorer(targetFile),
                                      child: Text(targetFile.path, style: const TextStyle(fontSize: 14)),
                                    ),
                                    Divider(),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children:
                                            sourceFiles
                                                .map(
                                                  (f) => InkWell(
                                                    onTap: () => openFileInExplorer(f),
                                                    child: Text(
                                                      f.path,
                                                      style: const TextStyle(
                                                        fontSize: 13,
                                                        color: Colors.blue,
                                                      ),
                                                    ),
                                                  ),
                                                )
                                                .toList(),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
              ),
            ),
          ),
          Container(
            color: Colors.grey.shade100,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ElevatedButton(
                  onPressed:
                      _stageFinished
                          ? () {
                            if (selected.length < duplicateGroups.length) {
                              selected = duplicateGroups.keys.toSet();
                            } else {
                              selected.clear();
                            }
                            total = selected.length;
                            handled = 0;
                            progress = 0;
                            _updateState("");
                          }
                          : null,
                  child: Text((selected.length == duplicateGroups.length) ? '取消全选' : '全选'),
                ),
                const Spacer(),
                HoverCheckboxLabel(
                  label: '强制删除',
                  value: _forceDelete,
                  onChanged: () {
                    setState(() {
                      _forceDelete = !_forceDelete;
                    });
                  },
                ),
                const SizedBox(width: 8.0),
                ElevatedButton(
                  onPressed:
                      _stageFinished && selected.isNotEmpty
                          ? () async {
                            await performDedup();

                            showDialog(
                              context: context,
                              builder:
                                  (context) => AlertDialog(
                                    title: Text('完成'),
                                    content: Text('文件硬链接去重已完成！'),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.of(context).pop(),
                                        child: Text('确定'),
                                      ),
                                    ],
                                  ),
                            );
                          }
                          : null,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  child: const Text('执行硬链接合并'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _updateState(String msg) {
    print(msg);

    setState(() {
      _currentState = msg;
    });
  }

  Future<void> selectDirectory() async {
    final path = await getDirectoryPath();
    if (path != null) {
      selectedDir = path;
      duplicateGroups.clear();
      selected.clear();
      allFiles.clear();
      total = 0;
      handled = 0;
      progress = 0;
      _stageFinished = false;
      _updateState("初始化...");
      await computeHashesWithScan(Directory(path));
    }
  }

  Future<void> computeHashesWithScan(Directory dir) async {
    Map<String, List<File>> hashedFileMap = {};

    var files =
        await dir.list(recursive: true, followLinks: false).where((e) => e is File).cast<File>().toList();
    files.sort((a, b) => basenameWithoutExtension(a.path).compareTo(basenameWithoutExtension(b.path)));

    total = files.length;

    for (var i = 0; i < files.length; i++) {
      var file = files[i];
      handled = i + 1;
      progress = (i + 1) / total;
      _updateState(file.path);

      String hash = await sha256OfFile(file);
      hashedFileMap.putIfAbsent(hash, () => []).add(file);
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

    duplicateGroups = {
      for (var e in hashedFileMap.entries)
        if (e.value.length > 1) e.key: e.value,
    };

    _stageFinished = true;
    _updateState('扫描完成, 共找到 ${duplicateGroups.length} 组重复文件。');
  }

  Future<String> sha256OfFile(File file) async {
    var bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  void openFileInExplorer(File file) {
    final path = file.absolute.path;
    Process.run('explorer', ['/select,', path]);
  }

  Future<void> performDedup() async {
    var groups = selected.toList();

    total = groups.length;
    for (var i = 0; i < total; i++) {
      var group = groups[i];
      handled = i + 1;
      progress = (i + 1) / total;

      var files = duplicateGroups[group]!;
      var original = files.groupTarget;

      for (var duplicate in files.groupSourceFiles) {
        try {
          // duplicate.deleteSync();
          // 确保删除
          while (duplicate.existsSync()) {
            moveToRecycleBin(duplicate.path); // 使用回收站
          }

          bool ok = createHardLink(duplicate.path, original.path);

          _updateState('替换 ${duplicate.path} -> ${original.path} ${ok ? "成功" : "失败"}');
        } catch (e) {
          _updateState('错误 ${duplicate.path}: $e');
        }
      }
    }

    _stageFinished = true;
    _updateState('合并完成');
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

class HoverCheckboxLabel extends StatefulWidget {
  final bool value;
  final VoidCallback onChanged;
  final String label;

  const HoverCheckboxLabel({super.key, required this.value, required this.onChanged, required this.label});

  @override
  State<HoverCheckboxLabel> createState() => _HoverCheckboxLabelState();
}

class _HoverCheckboxLabelState extends State<HoverCheckboxLabel> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: widget.onChanged,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.value ? Icons.check_box : Icons.check_box_outline_blank, color: Colors.blue),
                if (_isHovered) const SizedBox(width: 5),
                if (_isHovered)
                  AnimatedOpacity(
                    opacity: _isHovered ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Text(widget.label),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

extension on List<File> {
  File get groupTarget => this.first;

  List<File> get groupSourceFiles => this.sublist(1);
}
