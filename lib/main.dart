import 'dart:io';
import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:crypto/crypto.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hardlink Dedup',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue), useMaterial3: true),
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

  Map<String, List<File>> duplicateGroups = {}; // sha256 -> files

  Set<String> selectedHashes = {}; // hashes selected for merging

  String logText = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hardlink Dedup')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(children: [Expanded(child: Text(selectedDir ?? '请选择一个目录')), ElevatedButton(onPressed: selectDirectory, child: const Text('选择目录'))]),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                children:
                    duplicateGroups.entries.map((entry) {
                      String hash = entry.key;
                      List<File> files = entry.value;
                      return CheckboxListTile(
                        title: Text('共 ${files.length} 个重复文件'),
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
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: files.map((f) => Text(f.path)).toList()),
                      );
                    }).toList(),
              ),
            ),
            ElevatedButton(onPressed: performDedup, child: const Text('执行硬链接合并')),
            const SizedBox(height: 10),
            Expanded(child: SingleChildScrollView(child: Text(logText))),
          ],
        ),
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
        logText = '';
      });
      await scanDirectory(Directory(path));
    }
  }

  Future<void> scanDirectory(Directory dir) async {
    Map<int, List<File>> sizeMap = {};

    await for (var entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        int size = await entity.length();
        sizeMap.putIfAbsent(size, () => []).add(entity);
      }
    }

    Map<String, List<File>> hashMap = {};

    for (var files in sizeMap.values) {
      if (files.length < 2) continue;
      for (var file in files) {
        String hash = await sha256OfFile(file);
        hashMap.putIfAbsent(hash, () => []).add(file);
      }
    }

    setState(() {
      duplicateGroups = {
        for (var e in hashMap.entries)
          if (e.value.length > 1) e.key: e.value,
      };
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

      for (var duplicate in files.skip(1)) {
        try {
          duplicate.deleteSync();
          bool ok = createHardLink(duplicate.path, original.path);
          setState(() {
            logText += '替换 ${duplicate.path} -> ${original.path} ${ok ? "成功" : "失败"}\n';
          });
        } catch (e) {
          setState(() {
            logText += '错误 ${duplicate.path}: $e\n';
          });
        }
      }
    }
  }

  // FFI 调用 Windows API
  bool createHardLink(String linkPath, String existingFilePath) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final CreateHardLink = kernel32
        .lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>), int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)>(
          'CreateHardLinkW',
        );

    final link = linkPath.toNativeUtf16();
    final target = existingFilePath.toNativeUtf16();

    final result = CreateHardLink(link, target, nullptr);

    calloc.free(link);
    calloc.free(target);

    return result != 0;
  }
}
