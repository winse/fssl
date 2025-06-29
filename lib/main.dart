import 'dart:io';
import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:crypto/crypto.dart';
import 'package:win32/win32.dart'; // 用于调用 SHFileOperation 放入回收站

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FSSL - File Space Saving Linking',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
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
  Set<String> selectedHashes = {};

  List<File> allFiles = [];
  int totalFiles = 0;
  int hashedFiles = 0;
  String currentFile = '';
  double progress = 0;

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
          if (totalFiles > 0)
            Container(
              color: Colors.green.shade50,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('已扫描文件: $hashedFiles / $totalFiles'),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 4),
                  Text(
                    '当前: $currentFile',
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
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Checkbox(
                              value: selectedHashes.contains(hash),
                              onChanged: (checked) {
                                setState(() {
                                  if (checked == true) {
                                    selectedHashes.add(hash);
                                  } else {
                                    selectedHashes.remove(hash);
                                  }
                                });
                              },
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children:
                                      files
                                          .map(
                                            (f) => Text(
                                              f.path,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.blue,
                                                decoration: TextDecoration.underline,
                                              ),
                                            ),
                                          )
                                          .toList(),
                                ),
                              ),
                            ),
                          ],
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
                  onPressed: () {
                    setState(() {
                      if (selectedHashes.length < duplicateGroups.length) {
                        selectedHashes = duplicateGroups.keys.toSet();
                      } else {
                        selectedHashes.clear();
                      }
                    });
                  },
                  child: const Text('全选 / 取消全选'),
                ),
                const Spacer(),
                ElevatedButton(
                  onPressed: performDedup,
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

  Future<void> selectDirectory() async {
    final path = await getDirectoryPath();
    if (path != null) {
      setState(() {
        selectedDir = path;
        duplicateGroups.clear();
        selectedHashes.clear();
        allFiles.clear();
        totalFiles = 0;
        hashedFiles = 0;
        currentFile = '';
        progress = 0;
      });
      await computeHashesWithScan(Directory(path));
    }
  }

  Future<void> computeHashesWithScan(Directory dir) async {
    Map<int, List<File>> sizeMap = {};
    Map<String, List<File>> hashMap = {};
    var files =
        await dir
            .list(recursive: true, followLinks: false)
            .where((e) => e is File)
            .cast<File>()
            .toList();
    totalFiles = files.length;

    for (var i = 0; i < files.length; i++) {
      var file = files[i];
      setState(() {
        currentFile = file.path;
        hashedFiles = i + 1;
        progress = (i + 1) / totalFiles;
      });

      int size = await file.length();
      sizeMap.putIfAbsent(size, () => []).add(file);

      if (sizeMap[size]!.length > 1) {
        String hash = await sha256OfFile(file);
        hashMap.putIfAbsent(hash, () => []).add(file);
      }
    }

    setState(() {
      duplicateGroups = {
        for (var e in hashMap.entries)
          if (e.value.length > 1) e.key: e.value,
      };
      currentFile = '扫描完成';
    });
  }

  Future<String> sha256OfFile(File file) async {
    var bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  Future<void> performDedup() async {
    for (var hash in selectedHashes) {
      var files = duplicateGroups[hash]!;
      var original = files.first;

      // var originalStat = original.statSync();
      var originalMeta = original.resolveSymbolicLinksSync();

      for (var duplicate in files.skip(1)) {
        var duplicateMeta = duplicate.resolveSymbolicLinksSync();
        // 如果已经指向同一个物理文件路径，跳过
        if (originalMeta == duplicateMeta) {
          setState(() {
            currentFile = '${duplicate.path} 已经与 ${original.path} 链接，跳过';
          });
          continue;
        }

        try {
          // duplicate.deleteSync();
          moveToRecycleBin(duplicate.path); // 使用回收站
          bool ok = createHardLink(duplicate.path, original.path);
          setState(() {
            currentFile = '替换 ${duplicate.path} -> ${original.path} ${ok ? "成功" : "失败"}';
          });
        } catch (e) {
          setState(() {
            currentFile = '错误 ${duplicate.path}: $e';
          });
        }
      }
    }
  }

  void moveToRecycleBin(String path) {
    final op =
        calloc<SHFILEOPSTRUCT>()
          ..ref.wFunc = FO_DELETE
          ..ref.pFrom = path.toNativeUtf16()
          ..ref.fFlags = OFN_ALLOWMULTISELECT | FOF_ALLOWUNDO | FOF_NOCONFIRMATION;

    SHFileOperation(op);
    calloc.free(op.ref.pFrom);
    calloc.free(op);
  }

  bool createHardLink(String linkPath, String existingFilePath) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final CreateHardLink = kernel32.lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
      int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)
    >('CreateHardLinkW');

    final link = linkPath.toNativeUtf16();
    final target = existingFilePath.toNativeUtf16();

    final result = CreateHardLink(link, target, nullptr);

    calloc.free(link);
    calloc.free(target);

    return result != 0;
  }
}
