import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import './dedup_controller.dart';
import 'dedup_isolate.dart';

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
  String? _selectedDir;

  Map<String, List<File>> _duplicateGroups = {};
  Set<String> _selected = {};

  int _total = 0;
  int _handled = 0;
  String _currentState = '';
  double _progress = 0;

  bool _stageFinished = false;
  bool _forceDelete = false;

  final controller = DedupController();

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
                Expanded(child: Text(_selectedDir ?? '请选择一个目录')),
                ElevatedButton(onPressed: handleSelectDirectory, child: const Text('选择目录')),
              ],
            ),
          ),
          Container(
            color: Colors.green.shade50,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('文件: $_handled / $_total'),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 4),
                Text(_currentState, softWrap: true, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: Colors.orange.shade50,
              child: ListView(
                children:
                    _duplicateGroups.entries.map((entry) {
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
                                value: _selected.contains(hash),
                                onChanged: (checked) {
                                  setState(() {
                                    if (checked == true) {
                                      _selected.add(hash);
                                    } else {
                                      _selected.remove(hash);
                                    }
                                    _updateSelectedGroup();
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
                            if (_selected.length < _duplicateGroups.length) {
                              _selected = _duplicateGroups.keys.toSet();
                            } else {
                              _selected.clear();
                            }
                            _updateSelectedGroup();
                          }
                          : null,
                  child: Text((_selected.length == _duplicateGroups.length) ? '取消全选' : '全选'),
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
                      _stageFinished && _selected.isNotEmpty
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

  void _updateState(int value, int total, String msg) {
    print(msg);

    setState(() {
      _handled = value;
      _total = total;
      _progress = value / total;
      _currentState = msg;
    });
  }

  void _stateFinished(bool state, String msg) {
    setState(() {
      _currentState = msg;
      _stageFinished = state;
    });
  }

  void _updateSelectedGroup() {
    _updateState(0, _selected.length, "选择组 ${_selected.length}/${_duplicateGroups.length}");
  }

  Future<void> handleSelectDirectory() async {
    final path = await getDirectoryPath();
    if (path != null) {
      _selectedDir = path;

      _duplicateGroups.clear();
      _selected.clear();
      _stateFinished(false, "初始化...");

      _duplicateGroups = await controller.computeHashesWithScan(
        Directory(path), //
        (value, total, msg) {
          _updateState(value, total, msg);
        },
      );
      _stateFinished(true, '扫描完成, 共找到 ${_duplicateGroups.length} 组重复文件。');
    }
  }

  Future<void> computeHashesWithScan(Directory dir) async {}

  void openFileInExplorer(File file) {
    final path = file.absolute.path;
    Process.run('explorer', ['/select,', path]);
  }

  Future<void> performDedup() async {
    var groups = _selected.toList();

    await controller.performDedups(
      groups, //
      _duplicateGroups,
      (int handled, int total, DedupResponse response) {
        if (response is DedupMessageResponse) {
          final duplicate = response.duplicate;
          final original = response.original;

          final ok = response.success;
          if (ok) {
            _updateState(handled, total, '替换 ${duplicate.path} -> ${original.path} 成功.');
          } else {
            _updateState(handled, total, '错误 ${duplicate.path}: ${response.error}');
          }
        }
      },
    );
    _stateFinished(true, '合并完成');
  }
}

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
