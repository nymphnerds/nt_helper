import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:nt_helper/cubit/disting_cubit.dart';
import 'package:nt_helper/domain/i_disting_midi_manager.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../poly_multisample/decent_sampler_converter.dart';
import '../../poly_multisample/poly_multisample_models.dart';
import '../../poly_multisample/poly_multisample_parser.dart';
import '../../poly_multisample/wav_metadata.dart';

class PolyMultisampleBuilderScreen extends StatefulWidget {
  const PolyMultisampleBuilderScreen({super.key});

  @override
  State<PolyMultisampleBuilderScreen> createState() =>
      _PolyMultisampleBuilderScreenState();
}

enum _DecentImportSourceKind { file, folder }

enum _PolyMultisampleSourceMode { local, ntSd, custom }

enum _CustomDraftSeed { empty, files, folder }

enum _AddWavMappingMode { preserve, unmapped, spread, roundRobin }

class _PolyMultisampleBuilderScreenState
    extends State<PolyMultisampleBuilderScreen> {
  static const _lastLocalSampleFolderKey =
      'poly_multisample.last_local_sample_folder';
  static const _lastDecentSourceFolderKey =
      'poly_multisample.last_decent_source_folder';
  static const _lastImportOutputFolderKey =
      'poly_multisample.last_import_output_folder';
  static const _lastCustomSourceFolderKey =
      'poly_multisample.last_custom_source_folder';
  static const _legacyLastDecentOutputFolderKey =
      'poly_multisample.last_decent_output_folder';

  PolySampleInstrument? _instrument;
  PolySampleRegion? _selectedRegion;
  _PolyMultisampleSourceMode? _sourceMode;
  bool _loading = false;
  String? _error;
  String? _lastLocalSampleFolder;
  String? _lastDecentSourceFolder;
  String? _lastImportOutputFolder;
  String? _lastCustomSourceFolder;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPickerPreferences());
  }

  Future<void> _loadPickerPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _lastLocalSampleFolder = prefs.getString(_lastLocalSampleFolderKey);
      _lastDecentSourceFolder = prefs.getString(_lastDecentSourceFolderKey);
      _lastImportOutputFolder =
          prefs.getString(_lastImportOutputFolderKey) ??
          prefs.getString(_legacyLastDecentOutputFolderKey);
      _lastCustomSourceFolder = prefs.getString(_lastCustomSourceFolderKey);
    });
  }

  String? _existingDirectory(String? path) {
    if (path == null || path.isEmpty) return null;
    return Directory(path).existsSync() ? path : null;
  }

  String _directoryForPath(String path) {
    return Directory(path).existsSync() ? path : p.dirname(path);
  }

  Future<void> _savePickerPreference(String key, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, path);
  }

  Future<void> _chooseFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose Disting sample folder',
      initialDirectory: _existingDirectory(_lastLocalSampleFolder),
    );
    if (path == null) return;
    setState(() => _lastLocalSampleFolder = path);
    unawaited(_savePickerPreference(_lastLocalSampleFolderKey, path));
    await _loadFolder(path);
  }

  Future<void> _loadFolder(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final instrument = await PolyMultisampleFolderReader.readDirectory(path);
      setState(() {
        _instrument = instrument;
        _sourceMode = _PolyMultisampleSourceMode.local;
        _selectedRegion = instrument.regions.isEmpty
            ? null
            : instrument.regions.first;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _chooseNtSdFolder() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final manager = context.read<DistingCubit>().disting();
      if (manager == null) {
        throw Exception('Connect to Disting NT first.');
      }
      final folders = await PolyMultisampleSdReader.listSampleFolders(manager);
      if (!mounted) return;
      setState(() => _loading = false);
      final selectedPath = await showDialog<String>(
        context: context,
        builder: (context) => _SdFolderPickerDialog(folders: folders),
      );
      if (selectedPath == null) return;
      await _loadNtSdFolder(selectedPath);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadNtSdFolder(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final manager = context.read<DistingCubit>().disting();
      if (manager == null) {
        throw Exception('Connect to Disting NT first.');
      }
      final instrument = await PolyMultisampleSdReader.readDirectory(
        manager,
        path,
      );
      setState(() {
        _instrument = instrument;
        _sourceMode = _PolyMultisampleSourceMode.ntSd;
        _selectedRegion = instrument.regions.isEmpty
            ? null
            : instrument.regions.first;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _importDecentSampler() async {
    final sourcePath = await _chooseDecentSourcePath();
    if (sourcePath == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    var options = const DecentSamplerConvertOptions();
    try {
      final analysis = await DecentSamplerConverter().analyze(
        sourcePath: sourcePath,
      );
      if (!mounted) return;
      setState(() => _loading = false);
      if (analysis.hasAmbiguousOverlaps && analysis.groups.length > 1) {
        final chosen = await showDialog<DecentSamplerConvertOptions>(
          context: context,
          builder: (context) => _DecentImportOptionsDialog(analysis: analysis),
        );
        if (chosen == null) return;
        options = chosen;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
      return;
    }

    final outputPath = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose folder for Disting NT output',
      initialDirectory:
          _existingDirectory(_lastImportOutputFolder) ??
          _existingDirectory(_lastLocalSampleFolder) ??
          _existingDirectory(_lastDecentSourceFolder),
    );
    if (outputPath == null) return;
    setState(() => _lastImportOutputFolder = outputPath);
    unawaited(_savePickerPreference(_lastImportOutputFolderKey, outputPath));

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await DecentSamplerConverter().convert(
        sourcePath: sourcePath,
        outputParentPath: outputPath,
        options: options,
      );
      if (!mounted) return;
      final firstFolder = result.outputFolders.isEmpty
          ? null
          : result.outputFolders.first;
      if (firstFolder == null) {
        throw Exception('No output folder was created.');
      }
      final instrument = await PolyMultisampleFolderReader.readDirectory(
        firstFolder,
      );
      if (!mounted) return;
      setState(() {
        _instrument = instrument;
        _sourceMode = _PolyMultisampleSourceMode.local;
        _selectedRegion = instrument.regions.isEmpty
            ? null
            : instrument.regions.first;
      });
      await _showConversionResult(result);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<String?> _chooseDecentSourcePath() async {
    final sourceKind = await showDialog<_DecentImportSourceKind>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import'),
        content: const Text(
          'Decent Sampler format only. Choose a .dslibrary, .zip, .dspreset, or an already extracted folder.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          OutlinedButton.icon(
            onPressed: () =>
                Navigator.of(context).pop(_DecentImportSourceKind.folder),
            icon: const Icon(Icons.folder_open),
            label: const Text('Extracted folder'),
          ),
          FilledButton.icon(
            onPressed: () =>
                Navigator.of(context).pop(_DecentImportSourceKind.file),
            icon: const Icon(Icons.file_open),
            label: const Text('File / archive'),
          ),
        ],
      ),
    );
    if (sourceKind == null) return null;

    if (sourceKind == _DecentImportSourceKind.folder) {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose extracted Decent Sampler folder',
        initialDirectory: _existingDirectory(_lastDecentSourceFolder),
      );
      if (path != null) {
        setState(() => _lastDecentSourceFolder = path);
        unawaited(_savePickerPreference(_lastDecentSourceFolderKey, path));
      }
      return path;
    }

    final source = await FilePicker.pickFiles(
      dialogTitle: 'Choose Decent Sampler library or preset',
      type: FileType.custom,
      allowedExtensions: const ['dspreset', 'dslibrary', 'zip'],
      allowMultiple: false,
      initialDirectory: _existingDirectory(_lastDecentSourceFolder),
    );
    final path = source?.files.single.path;
    if (path != null) {
      final sourceFolder = _directoryForPath(path);
      setState(() => _lastDecentSourceFolder = sourceFolder);
      unawaited(
        _savePickerPreference(_lastDecentSourceFolderKey, sourceFolder),
      );
    }
    return path;
  }

  Future<void> _startCustomDraft() async {
    final seed = await showDialog<_CustomDraftSeed>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Custom multisample'),
        content: const Text(
          'Collect loose WAVs, folders, or selected WAVs/groups from Decent '
          'Sampler .dslibrary, .zip, or .dspreset sources, then map and save '
          'them as a Disting NT multisample folder.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(_CustomDraftSeed.empty),
            icon: const Icon(Icons.add_box_outlined),
            label: const Text('Empty draft'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(_CustomDraftSeed.folder),
            icon: const Icon(Icons.folder_open),
            label: const Text('Add folder'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(_CustomDraftSeed.files),
            icon: const Icon(Icons.audio_file),
            label: const Text('Add files'),
          ),
        ],
      ),
    );
    if (seed == null) return;

    var regions = <PolySampleRegion>[];
    if (seed == _CustomDraftSeed.files) {
      regions = await _pickCustomSourceFiles();
      if (regions.isEmpty) return;
    } else if (seed == _CustomDraftSeed.folder) {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose source folder',
        initialDirectory:
            _existingDirectory(_lastCustomSourceFolder) ??
            _existingDirectory(_lastLocalSampleFolder) ??
            _existingDirectory(_lastImportOutputFolder),
      );
      if (path == null) return;
      if (!mounted) return;
      setState(() => _lastCustomSourceFolder = path);
      unawaited(_savePickerPreference(_lastCustomSourceFolderKey, path));
      regions = await _pickSelectedDecentWavs(context, path);
      if (regions.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No WAV files found in that folder.')),
        );
      }
    }

    PolyMultisampleFolderReader.sortRegions(regions);
    setState(() {
      _instrument = PolySampleInstrument(
        name: 'Custom draft',
        sourcePath: 'Custom draft (not saved)',
        regions: regions,
      );
      _sourceMode = _PolyMultisampleSourceMode.custom;
      _selectedRegion = regions.isEmpty ? null : regions.first;
      _error = null;
    });
  }

  Future<List<PolySampleRegion>> _pickCustomSourceFiles() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Choose WAVs or Decent Sampler sources',
      type: FileType.custom,
      allowedExtensions: const ['wav', 'dspreset', 'dslibrary', 'zip'],
      allowMultiple: true,
      initialDirectory:
          _existingDirectory(_lastCustomSourceFolder) ??
          _existingDirectory(_lastLocalSampleFolder) ??
          _existingDirectory(_lastImportOutputFolder),
    );
    final paths = result?.files.map((file) => file.path).nonNulls.toList();
    if (paths == null || paths.isEmpty) return const [];
    final folder = p.dirname(paths.first);
    setState(() => _lastCustomSourceFolder = folder);
    unawaited(_savePickerPreference(_lastCustomSourceFolderKey, folder));
    final regions = <PolySampleRegion>[];
    final wavFiles = <File>[];
    for (final path in paths) {
      final extension = p.extension(path).toLowerCase();
      if (extension == '.wav') {
        wavFiles.add(File(path));
      } else {
        if (!mounted) return regions;
        regions.addAll(await _pickSelectedDecentWavs(context, path));
      }
    }
    if (wavFiles.isNotEmpty) {
      if (!mounted) return regions;
      final groups = _groupsFromLocalWavs(
        wavFiles,
        _commonParentPath(wavFiles),
      );
      regions.addAll(await _pickSelectedWavGroups(context, groups));
    }
    return regions;
  }

  Future<void> _loadSavedCustomFolder(String path) async {
    await _loadFolder(path);
  }

  Future<void> _showConversionResult(
    DecentSamplerConversionResult result,
  ) async {
    if (!mounted) return;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Decent import complete'),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(result.summary, style: theme.textTheme.bodyLarge),
                const SizedBox(height: 16),
                Text(
                  result.outputFolders.length == 1
                      ? 'Loaded output folder'
                      : 'Loaded output folders',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                SelectableText(
                  result.outputFolders.join('\n'),
                  style: theme.textTheme.bodyMedium,
                ),
                if (result.decisions.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Conversion choices', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  for (final decision in result.decisions.take(8))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(decision, style: theme.textTheme.bodyMedium),
                    ),
                ],
                if (result.warnings.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Warnings', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  for (final warning in result.warnings.take(8))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        warning,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (result.outputFolders.isNotEmpty)
            TextButton.icon(
              onPressed: () =>
                  unawaited(_openFolderPath(result.outputFolders.first)),
              icon: const Icon(Icons.folder_open),
              label: const Text('Open folder'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _openFolderPath(String dir) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      } else {
        await Process.run('xdg-open', [dir]);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open folder: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final instrument = _instrument;
    final ntSdSelected = _sourceMode == _PolyMultisampleSourceMode.ntSd;
    final localSelected = _sourceMode == _PolyMultisampleSourceMode.local;
    final customSelected = _sourceMode == _PolyMultisampleSourceMode.custom;

    return Column(
      children: [
        Material(
          color: colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                const Icon(Icons.audio_file),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Poly Multisample Builder',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        instrument?.sourcePath ??
                            'Choose a sample folder to inspect',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                _SourceButton(
                  selected: ntSdSelected,
                  onPressed: _loading ? null : _chooseNtSdFolder,
                  icon: Icons.memory,
                  label: 'NT SD',
                ),
                const SizedBox(width: 8),
                _SourceButton(
                  selected: localSelected,
                  onPressed: _loading ? null : _chooseFolder,
                  icon: Icons.folder_open,
                  label: 'Local',
                ),
                const SizedBox(width: 8),
                _SourceButton(
                  selected: customSelected,
                  onPressed: _loading ? null : _startCustomDraft,
                  icon: Icons.playlist_add,
                  label: 'Custom',
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _importDecentSampler,
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('Import'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Export'),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _ErrorView(message: _error!, onRetry: _chooseFolder)
              : instrument == null
              ? _EmptyBuilderView(
                  onChooseFolder: _chooseFolder,
                  onChooseNtSdFolder: _chooseNtSdFolder,
                  onImportDecentSampler: _importDecentSampler,
                  onStartCustomDraft: _startCustomDraft,
                )
              : _InstrumentEditor(
                  instrument: instrument,
                  isCustomDraft: customSelected,
                  selectedRegion: _selectedRegion,
                  onChooseFolder: _chooseFolder,
                  onSelectRegion: (region) {
                    setState(() => _selectedRegion = region);
                  },
                  onCustomSaved: _loadSavedCustomFolder,
                ),
        ),
      ],
    );
  }
}

class _SourceButton extends StatelessWidget {
  const _SourceButton({
    required this.selected,
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final bool selected;
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (selected) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

class _EmptyBuilderView extends StatelessWidget {
  const _EmptyBuilderView({
    required this.onChooseFolder,
    required this.onChooseNtSdFolder,
    required this.onImportDecentSampler,
    required this.onStartCustomDraft,
  });

  final VoidCallback onChooseFolder;
  final VoidCallback onChooseNtSdFolder;
  final VoidCallback onImportDecentSampler;
  final VoidCallback onStartCustomDraft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.audio_file, size: 56, color: colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Build a Disting NT multisample folder',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'Open an existing /samples instrument folder, or build your own from loose WAVs, folders, and selected Decent Sampler WAVs/groups.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: onChooseNtSdFolder,
                  icon: const Icon(Icons.memory),
                  label: const Text('Browse NT SD'),
                ),
                OutlinedButton.icon(
                  onPressed: onChooseFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Open Local Folder'),
                ),
                OutlinedButton.icon(
                  onPressed: onStartCustomDraft,
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Custom'),
                ),
                OutlinedButton.icon(
                  onPressed: onImportDecentSampler,
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('Import'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Import currently supports Decent Sampler format only: .dslibrary, .zip, .dspreset, or extracted folders.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _SdFolderPickerDialog extends StatelessWidget {
  const _SdFolderPickerDialog({required this.folders});

  final List<String> folders;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Disting NT Samples'),
      content: SizedBox(
        width: 520,
        height: 520,
        child: folders.isEmpty
            ? Center(
                child: Text(
                  'No sample folders found in /samples.',
                  style: theme.textTheme.bodyMedium,
                ),
              )
            : ListView.separated(
                itemCount: folders.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final folder = folders[index];
                  final name = folder
                      .split('/')
                      .where((s) => s.isNotEmpty)
                      .last;
                  return ListTile(
                    leading: const Icon(Icons.folder_open),
                    title: Text(name),
                    subtitle: Text(folder),
                    onTap: () => Navigator.of(context).pop(folder),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _DecentImportOptionsDialog extends StatefulWidget {
  const _DecentImportOptionsDialog({required this.analysis});

  final DecentSamplerImportAnalysis analysis;

  @override
  State<_DecentImportOptionsDialog> createState() =>
      _DecentImportOptionsDialogState();
}

class _DecentImportOptionsDialogState
    extends State<_DecentImportOptionsDialog> {
  DecentSamplerGroupHandling _handling =
      DecentSamplerGroupHandling.velocityLayers;
  String? _selectedGroupKey;
  bool _includeSourceDocs = true;

  @override
  void initState() {
    super.initState();
    _handling = widget.analysis.recommendedGroupHandling;
    _selectedGroupKey = widget.analysis.groups.isEmpty
        ? null
        : widget.analysis.groups.first.key;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = widget.analysis.groups;
    return AlertDialog(
      title: const Text('Decent import strategy'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.analysis.presetName} contains Decent Sampler group mappings that need a choice. '
                'Each preset imports as its own Disting NT folder; these choices control how groups inside each preset are mapped.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 14),
              _DecentImportSummaryPanel(analysis: widget.analysis),
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(
                  'Detailed group report',
                  style: theme.textTheme.titleSmall,
                ),
                subtitle: Text(
                  '${groups.length} Decent group(s), shown for checking the import decision.',
                ),
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Column(
                      children: [
                        for (var index = 0; index < groups.length; index++)
                          _GroupReportRow(
                            group: groups[index],
                            showDivider: index < groups.length - 1,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text('Import choices', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              _ImportOptionTile(
                value: DecentSamplerGroupHandling.velocityLayers,
                groupValue: _handling,
                title: 'Use groups as velocity layers',
                subtitle:
                    'Groups become V1, V2, V3 etc. Round robins stay round robins.',
                onChanged: _setHandling,
              ),
              _ImportOptionTile(
                value: DecentSamplerGroupHandling.splitFolders,
                groupValue: _handling,
                title: 'Split groups into separate folders',
                subtitle:
                    'One Disting folder per group/layer/articulation. Round robins stay round robins.',
                onChanged: _setHandling,
              ),
              _ImportOptionTile(
                value: DecentSamplerGroupHandling.selectedGroup,
                groupValue: _handling,
                title: 'Convert one group only',
                subtitle: 'Choose one Decent group and ignore the others.',
                onChanged: _setHandling,
              ),
              if (_handling == DecentSamplerGroupHandling.selectedGroup) ...[
                const SizedBox(height: 8),
                for (final group in groups)
                  _SelectedGroupRow(
                    group: group,
                    selected: group.key == _selectedGroupKey,
                    onTap: () => setState(() => _selectedGroupKey = group.key),
                  ),
              ],
              _ImportOptionTile(
                value: DecentSamplerGroupHandling.auto,
                groupValue: _handling,
                title: 'Default mapping',
                subtitle:
                    'Keep the automatic parser behavior and report any ambiguity.',
                onChanged: _setHandling,
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: _includeSourceDocs,
                onChanged: (value) =>
                    setState(() => _includeSourceDocs = value),
                contentPadding: EdgeInsets.zero,
                title: const Text('Include source docs/licenses'),
                subtitle: const Text(
                  'Copies likely license, readme, manual, info, and artwork files into _source_docs.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              DecentSamplerConvertOptions(
                groupHandling: _handling,
                selectedGroupKey:
                    _handling == DecentSamplerGroupHandling.selectedGroup
                    ? _selectedGroupKey
                    : null,
                includeSourceDocs: _includeSourceDocs,
              ),
            );
          },
          child: const Text('Continue'),
        ),
      ],
    );
  }

  void _setHandling(DecentSamplerGroupHandling? value) {
    if (value == null) return;
    setState(() => _handling = value);
  }
}

class _DecentImportSummaryPanel extends StatelessWidget {
  const _DecentImportSummaryPanel({required this.analysis});

  final DecentSamplerImportAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final facts = _DecentImportFacts.from(analysis);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.22),
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What this looks like', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            _SummaryBullet('${facts.groupCount} groups'),
            _SummaryBullet('${facts.sampleCount} samples'),
            _SummaryBullet(
              '${facts.labelledGroupCount} labelled group/layer names',
            ),
            _SummaryBullet('${facts.roundRobinCount} round robins'),
            _SummaryBullet(
              '${facts.velocityRangeCount} explicit velocity ranges',
            ),
            if (facts.controllerSummary.isNotEmpty)
              _SummaryBullet(facts.controllerSummary),
            const SizedBox(height: 10),
            Text(
              facts.interpretation,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              facts.recommendation,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryBullet extends StatelessWidget {
  const _SummaryBullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Icon(
              Icons.circle,
              size: 5,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _DecentImportFacts {
  const _DecentImportFacts({
    required this.groupCount,
    required this.sampleCount,
    required this.labelledGroupCount,
    required this.roundRobinCount,
    required this.velocityRangeCount,
    required this.controllerSummary,
    required this.interpretation,
    required this.recommendation,
  });

  final int groupCount;
  final int sampleCount;
  final int labelledGroupCount;
  final int roundRobinCount;
  final int velocityRangeCount;
  final String controllerSummary;
  final String interpretation;
  final String recommendation;

  factory _DecentImportFacts.from(DecentSamplerImportAnalysis analysis) {
    final groups = analysis.groups;
    final rrValues = <int>{};
    final velocityRanges = <String>{};
    for (final group in groups) {
      final rrMatch = RegExp(
        r'RR\s+(\d+)(?:-(\d+))?',
      ).firstMatch(group.roundRobinSummary);
      if (rrMatch != null) {
        final start = int.tryParse(rrMatch.group(1) ?? '');
        final end = int.tryParse(rrMatch.group(2) ?? '') ?? start;
        if (start != null && end != null) {
          for (var value = start; value <= end; value++) {
            rrValues.add(value);
          }
        }
      }
      for (final match in RegExp(
        r'\b\d+-\d+\b',
      ).allMatches(group.velocitySummary)) {
        velocityRanges.add(match.group(0)!);
      }
    }

    final summary = analysis.structureSummary.toUpperCase();
    final controllerLabels = <String>[
      if (summary.contains('PAN')) 'pan',
      if (summary.contains('GROUP_TUNING')) 'tuning',
      if (summary.contains('ENABLED')) 'enabled/switching',
      if (summary.contains('AMP_VOLUME') || summary.contains('VOLUME'))
        'volume',
    ];
    final hasControllerBindings =
        summary.contains('CONTROL') || summary.contains('BIND');
    final controllerSummary = hasControllerBindings
        ? controllerLabels.isEmpty
              ? 'UI/controller bindings present'
              : 'lots of UI/controller bindings, especially ${controllerLabels.join('/')}'
        : '';

    final recommendation = switch (analysis.recommendedGroupHandling) {
      DecentSamplerGroupHandling.splitFolders =>
        'Recommended: split groups into separate folders.',
      DecentSamplerGroupHandling.velocityLayers =>
        'Recommended: use groups as velocity layers.',
      DecentSamplerGroupHandling.selectedGroup =>
        'Recommended: convert one group only.',
      DecentSamplerGroupHandling.auto =>
        'Recommended: keep the default parser mapping.',
    };

    final interpretation = hasControllerBindings
        ? 'This looks like a library with articulations/options or controller-mixed layers. A single Disting NT Poly Multisample folder cannot reproduce Decent Sampler UI controls directly.'
        : velocityRanges.length > 1
        ? 'This looks like a velocity-layered instrument. Velocity-layer import is likely useful.'
        : rrValues.length > 1
        ? 'This looks like a round-robin sample set. Round robins can be preserved.'
        : 'This looks like a simple sample set.';

    return _DecentImportFacts(
      groupCount: groups.length,
      sampleCount: groups.fold<int>(
        0,
        (total, group) => total + group.sampleCount,
      ),
      labelledGroupCount: groups
          .where((group) => !_isGenericDecentGroupName(group.name))
          .map((group) => group.name)
          .toSet()
          .length,
      roundRobinCount: rrValues.length,
      velocityRangeCount: velocityRanges.length,
      controllerSummary: controllerSummary,
      interpretation: interpretation,
      recommendation: recommendation,
    );
  }

  static bool _isGenericDecentGroupName(String name) {
    return RegExp(r'^Group \d+$').hasMatch(name.trim());
  }
}

String _decentGroupNumberLabel(DecentSamplerGroupInfo group) {
  final separator = group.key.indexOf(':');
  if (separator <= 0) return 'Group';
  final index = int.tryParse(group.key.substring(0, separator));
  return index == null ? 'Group' : 'Group ${index + 1}';
}

String? _decentXmlGroupName(DecentSamplerGroupInfo group) {
  final name = group.name.trim();
  if (name.isEmpty || RegExp(r'^Group \d+$').hasMatch(name)) return null;
  return name;
}

class _SelectedGroupRow extends StatelessWidget {
  const _SelectedGroupRow({
    required this.group,
    required this.selected,
    required this.onTap,
  });

  final DecentSamplerGroupInfo group;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final groupNumber = _decentGroupNumberLabel(group);
    final xmlName = _decentXmlGroupName(group);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.check_circle : Icons.circle_outlined,
        color: selected ? colorScheme.primary : colorScheme.outline,
      ),
      title: Text(xmlName == null ? groupNumber : '$groupNumber - $xmlName'),
      subtitle: Text(
        '${group.sampleCount} samples, ${group.noteRange}, ${group.roundRobinSummary}',
      ),
      onTap: onTap,
    );
  }
}

class _GroupReportRow extends StatelessWidget {
  const _GroupReportRow({required this.group, required this.showDivider});

  final DecentSamplerGroupInfo group;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final examples = group.examples.take(2).join(', ');
    final groupNumber = _decentGroupNumberLabel(group);
    final xmlName = _decentXmlGroupName(group);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 170,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      groupNumber,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (xmlName != null)
                      Text(
                        xmlName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else
                      Text(
                        'No XML name',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${group.sampleCount} samples, ${group.rootCount} roots, ${group.noteRange}. '
                  '${group.velocitySummary}; ${group.roundRobinSummary}. '
                  '${group.xmlSummary}. '
                  '${examples.isEmpty ? '' : 'Examples: $examples'}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (showDivider) Divider(height: 1, color: colorScheme.outlineVariant),
      ],
    );
  }
}

class _ImportOptionTile extends StatelessWidget {
  const _ImportOptionTile({
    required this.value,
    required this.groupValue,
    required this.title,
    required this.subtitle,
    required this.onChanged,
  });

  final DecentSamplerGroupHandling value;
  final DecentSamplerGroupHandling groupValue;
  final String title;
  final String subtitle;
  final ValueChanged<DecentSamplerGroupHandling?> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = value == groupValue;
    return ListTile(
      selected: selected,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.check_circle : Icons.circle_outlined,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: () => onChanged(value),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: colorScheme.error, size: 48),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.folder_open),
            label: const Text('Choose Folder'),
          ),
        ],
      ),
    );
  }
}

class _InstrumentEditor extends StatefulWidget {
  const _InstrumentEditor({
    required this.instrument,
    required this.isCustomDraft,
    required this.selectedRegion,
    required this.onChooseFolder,
    required this.onSelectRegion,
    required this.onCustomSaved,
  });

  final PolySampleInstrument instrument;
  final bool isCustomDraft;
  final PolySampleRegion? selectedRegion;
  final Future<void> Function() onChooseFolder;
  final ValueChanged<PolySampleRegion> onSelectRegion;
  final Future<void> Function(String path) onCustomSaved;

  @override
  State<_InstrumentEditor> createState() => _InstrumentEditorState();
}

class _InstrumentEditorState extends State<_InstrumentEditor> {
  static const _lastWavExportFolderKey =
      'poly_multisample.last_wav_export_folder';
  static const _lastCustomOutputFolderKey =
      'poly_multisample.last_custom_output_folder';
  static const _lastCustomSourceFolderKey =
      'poly_multisample.last_custom_source_folder';

  late List<PolySampleRegion> _regions;
  late List<PolySampleRegion> _baselineRegions;
  late List<_SampleLane> _mapLanes;
  late int _mapMinMidi;
  late int _mapMaxMidi;
  int _mapRevision = 0;
  final AudioPlayer _samplePlayer = AudioPlayer();
  final Map<String, WavOverview?> _waveformCache = {};
  final Map<String, Future<WavOverview?>> _waveformFutures = {};
  final Map<String, _LoopMarkerDraft> _loopDrafts = {};
  final Map<String, _LoopMarkerDraft> _savedLoopDrafts = {};
  final Map<String, bool> _loopMetadataPresent = {};
  final Map<String, bool> _loopEnabledDrafts = {};
  final Map<String, _WavEditDraft> _wavEditDrafts = {};
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<void>? _playerCompleteSubscription;
  String? _selectedPath;
  String? _playingPath;
  String? _loopPreviewFilePath;
  bool _playerPlaying = false;
  bool _loopPreviewEnabled = false;
  bool _applying = false;
  bool _savingLoop = false;
  bool _renderingWav = false;
  bool _autoPreviewOnSelect = false;
  double _previewGainDb = 0;
  _WaveformMode _waveformMode = _WaveformMode.metadata;
  String? _lastWavExportFolder;
  String? _lastCustomOutputFolder;
  String? _lastCustomSourceFolder;
  Set<String> _selectedPaths = {};
  int? _lastListSelectedIndex;

  @override
  void initState() {
    super.initState();
    _resetDraft();
    unawaited(_loadWavExportPreference());
    unawaited(_loadCustomOutputPreference());
    unawaited(_loadCustomSourcePreference());
    _playerStateSubscription = _samplePlayer.onPlayerStateChanged.listen((
      state,
    ) {
      if (!mounted) return;
      setState(() {
        _playerPlaying = state == PlayerState.playing;
        if (state == PlayerState.stopped) {
          if (!_loopPreviewEnabled) {
            _playingPath = null;
          }
        } else if (state == PlayerState.completed && !_loopPreviewEnabled) {
          _playingPath = null;
        }
      });
    });
    _playerCompleteSubscription = _samplePlayer.onPlayerComplete.listen((_) {
      if (_loopPreviewEnabled || !mounted) return;
      setState(() {
        _playingPath = null;
        _playerPlaying = false;
      });
    });
  }

  @override
  void didUpdateWidget(covariant _InstrumentEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.instrument, widget.instrument)) {
      _resetDraft();
    }
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    _clearLoopPreviewFile();
    _samplePlayer.dispose();
    super.dispose();
  }

  Future<void> _loadWavExportPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _lastWavExportFolder = prefs.getString(_lastWavExportFolderKey);
    });
  }

  Future<void> _loadCustomOutputPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _lastCustomOutputFolder = prefs.getString(_lastCustomOutputFolderKey);
    });
  }

  Future<void> _loadCustomSourcePreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _lastCustomSourceFolder = prefs.getString(_lastCustomSourceFolderKey);
    });
  }

  String? _existingDirectory(String? path) {
    if (path == null || path.isEmpty) return null;
    return Directory(path).existsSync() ? path : null;
  }

  Future<void> _saveWavExportFolder(String path) async {
    final folder = Directory(path).existsSync() ? path : p.dirname(path);
    setState(() => _lastWavExportFolder = folder);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastWavExportFolderKey, folder);
  }

  Future<void> _saveCustomOutputFolder(String path) async {
    setState(() => _lastCustomOutputFolder = path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastCustomOutputFolderKey, path);
  }

  Future<void> _saveCustomSourceFolder(String path) async {
    final folder = Directory(path).existsSync() ? path : p.dirname(path);
    setState(() => _lastCustomSourceFolder = folder);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastCustomSourceFolderKey, folder);
  }

  void _resetDraft() {
    _waveformCache.clear();
    _waveformFutures.clear();
    _loopDrafts.clear();
    _savedLoopDrafts.clear();
    _loopMetadataPresent.clear();
    _loopEnabledDrafts.clear();
    _wavEditDrafts.clear();
    _regions = _withExplicitSwitchPoints(widget.instrument.regions);
    _baselineRegions = List<PolySampleRegion>.of(_regions);
    _mapLanes = _sortedSampleLanes(_regions);
    _mapMinMidi = _initialMapMinMidi(_regions);
    _mapMaxMidi = _initialMapMaxMidi(_regions, _mapMinMidi);
    _mapRevision = 0;
    _selectedPath =
        widget.selectedRegion?.path ??
        (_regions.isEmpty ? null : _regions.first.path);
    _selectedPaths = _selectedPath == null ? {} : {_selectedPath!};
    _lastListSelectedIndex = _selectedPath == null
        ? null
        : _regions.indexWhere((region) => region.path == _selectedPath);
  }

  void _ensureMapLanes() {
    final lanes = _sortedSampleLanes(_regions);
    for (final lane in lanes) {
      if (!_mapLanes.contains(lane)) {
        _mapLanes.add(lane);
      }
    }
    _mapLanes.sort();
  }

  PolySampleRegion? get _selectedRegion {
    final selectedPath = _selectedPath;
    if (selectedPath == null) return null;
    for (final region in _regions) {
      if (region.path == selectedPath) return region;
    }
    return _regions.isEmpty ? null : _regions.first;
  }

  void _selectRegion(PolySampleRegion region) {
    setState(() {
      _selectedPath = region.path;
      _selectedPaths = {region.path};
      _lastListSelectedIndex = _regions.indexWhere(
        (candidate) => candidate.path == region.path,
      );
    });
    widget.onSelectRegion(region);
    if (_autoPreviewOnSelect && !_isNtSdPath(region.path)) {
      unawaited(_playSamplePreview(region));
    }
  }

  void _selectRegionFromList(
    PolySampleRegion region, {
    required bool toggle,
    required bool extend,
  }) {
    final index = _regions.indexWhere(
      (candidate) => candidate.path == region.path,
    );
    setState(() {
      _selectedPath = region.path;
      if (extend && _lastListSelectedIndex != null && index >= 0) {
        final start = math.min(_lastListSelectedIndex!, index);
        final end = math.max(_lastListSelectedIndex!, index);
        _selectedPaths = {for (var i = start; i <= end; i++) _regions[i].path};
      } else if (toggle) {
        final next = Set<String>.of(_selectedPaths);
        if (!next.remove(region.path)) {
          next.add(region.path);
        }
        _selectedPaths = next.isEmpty ? {region.path} : next;
        _lastListSelectedIndex = index < 0 ? _lastListSelectedIndex : index;
      } else {
        _selectedPaths = {region.path};
        _lastListSelectedIndex = index < 0 ? null : index;
      }
    });
    widget.onSelectRegion(region);
    if (_autoPreviewOnSelect && !_isNtSdPath(region.path)) {
      unawaited(_playSamplePreview(region));
    }
  }

  void _updateRegion(PolySampleRegion updated) {
    setState(() {
      final index = _regions.indexWhere(
        (region) => region.path == updated.path,
      );
      if (index < 0) return;
      _regions[index] = updated;
      _ensureMapLanes();
      _mapRevision++;
      _selectedPath = updated.path;
    });
    final selected = _selectedRegion;
    if (selected != null) {
      widget.onSelectRegion(selected);
    }
  }

  Future<void> _addCustomWavs() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Add WAVs or Decent Sampler sources',
      type: FileType.custom,
      allowedExtensions: const ['wav', 'dspreset', 'dslibrary', 'zip'],
      allowMultiple: true,
      initialDirectory:
          _existingDirectory(_lastCustomSourceFolder) ??
          _existingDirectory(_lastWavExportFolder) ??
          _existingDirectory(_lastCustomOutputFolder),
    );
    final paths = result?.files.map((file) => file.path).nonNulls.toList();
    if (paths == null || paths.isEmpty) return;
    final regions = <PolySampleRegion>[];
    final wavFiles = <File>[];
    for (final path in paths) {
      final extension = p.extension(path).toLowerCase();
      if (extension == '.wav') {
        wavFiles.add(File(path));
      } else {
        if (!mounted) return;
        regions.addAll(await _pickSelectedDecentWavs(context, path));
      }
    }
    if (wavFiles.isNotEmpty) {
      if (!mounted) return;
      final groups = _groupsFromLocalWavs(
        wavFiles,
        _commonParentPath(wavFiles),
      );
      regions.addAll(await _pickSelectedWavGroups(context, groups));
    }
    unawaited(_saveCustomSourceFolder(paths.first));
    _addCustomRegions(regions);
  }

  Future<void> _addCustomFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Add source folder',
      initialDirectory:
          _existingDirectory(_lastCustomSourceFolder) ??
          _existingDirectory(_lastWavExportFolder) ??
          _existingDirectory(_lastCustomOutputFolder),
    );
    if (path == null) return;
    if (!mounted) return;
    unawaited(_saveCustomSourceFolder(path));
    final regions = await _pickSelectedDecentWavs(context, path);
    if (regions.isEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No WAV files found in that folder.')),
      );
      return;
    }
    _addCustomRegions(regions);
  }

  void _addCustomRegions(Iterable<PolySampleRegion> regions) {
    final existing = _regions.map((region) => region.path).toSet();
    final additions = regions
        .where((region) => !existing.contains(region.path))
        .toList();
    if (additions.isEmpty) return;
    setState(() {
      _regions.addAll(additions);
      PolyMultisampleFolderReader.sortRegions(_regions);
      if (widget.isCustomDraft) {
        _baselineRegions = List<PolySampleRegion>.of(_regions);
      }
      _mapLanes = _sortedSampleLanes(_regions);
      _mapMinMidi = _initialMapMinMidi(_regions);
      _mapMaxMidi = _initialMapMaxMidi(_regions, _mapMinMidi);
      _mapRevision++;
      _selectedPath = additions.first.path;
      _selectedPaths = {additions.first.path};
      _lastListSelectedIndex = _regions.indexWhere(
        (region) => region.path == additions.first.path,
      );
    });
    final selected = _selectedRegion;
    if (selected != null) {
      widget.onSelectRegion(selected);
    }
  }

  void _removeSelectedRegions() {
    final targets = _selectedPaths.isEmpty
        ? {_selectedPath}.whereType<String>().toSet()
        : Set<String>.of(_selectedPaths);
    if (targets.isEmpty) return;
    final firstIndex = _regions.indexWhere(
      (region) => targets.contains(region.path),
    );
    if (firstIndex < 0) return;
    setState(() {
      _regions.removeWhere((region) => targets.contains(region.path));
      if (widget.isCustomDraft) {
        _baselineRegions = List<PolySampleRegion>.of(_regions);
      }
      for (final path in targets) {
        _waveformCache.remove(path);
        _waveformFutures.remove(path);
        _loopDrafts.remove(path);
        _savedLoopDrafts.remove(path);
        _loopMetadataPresent.remove(path);
        _loopEnabledDrafts.remove(path);
        _wavEditDrafts.remove(path);
      }
      _mapLanes = _sortedSampleLanes(_regions);
      _mapMinMidi = _initialMapMinMidi(_regions);
      _mapMaxMidi = _initialMapMaxMidi(_regions, _mapMinMidi);
      _mapRevision++;
      if (_regions.isEmpty) {
        _selectedPath = null;
        _selectedPaths = {};
        _lastListSelectedIndex = null;
      } else {
        final nextIndex = firstIndex.clamp(0, _regions.length - 1).toInt();
        _selectedPath = _regions[nextIndex].path;
        _selectedPaths = {_selectedPath!};
        _lastListSelectedIndex = nextIndex;
      }
    });
    final selected = _selectedRegion;
    if (selected != null) {
      widget.onSelectRegion(selected);
    }
    if (!widget.isCustomDraft && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            targets.length == 1
                ? 'Marked 1 sample for removal. Apply to delete it.'
                : 'Marked ${targets.length} samples for removal. Apply to delete them.',
          ),
        ),
      );
    }
  }

  Future<void> _saveCustomDraft({required bool saveAs}) async {
    if (!widget.isCustomDraft || _regions.isEmpty || _applying) return;
    var outputPath = saveAs ? null : _lastCustomOutputFolder;
    if (outputPath == null || !Directory(outputPath).existsSync()) {
      outputPath = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose custom Disting output folder',
        initialDirectory: _existingDirectory(_lastCustomOutputFolder),
      );
    }
    if (outputPath == null) return;

    setState(() => _applying = true);
    try {
      await Directory(outputPath).create(recursive: true);
      final copied = await _copyCustomDraftTo(outputPath);
      await _saveCustomOutputFolder(outputPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved ${copied.length} sample(s).')),
        );
      }
      await widget.onCustomSaved(outputPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Custom save failed: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _applying = false);
      }
    }
  }

  Future<List<String>> _copyCustomDraftTo(String outputPath) async {
    final reservedNames = <String, int>{};
    final copied = <String>[];
    for (final region in _regions) {
      final source = File(region.path);
      if (!await source.exists()) {
        throw Exception('Missing source WAV: ${region.path}');
      }
      final targetName = _targetSampleFileName(region, _regions, reservedNames);
      final targetPath = p.join(outputPath, targetName);
      await source.copy(targetPath);
      copied.add(targetName);
    }
    await _writeCustomBuildReport(outputPath, copied);
    return copied;
  }

  Future<void> _writeCustomBuildReport(
    String outputPath,
    List<String> copied,
  ) async {
    final buffer = StringBuffer()
      ..writeln('# Custom Multisample Build Report')
      ..writeln()
      ..writeln('Generated by NT Helper Poly Multisample Builder.')
      ..writeln()
      ..writeln('## Output')
      ..writeln()
      ..writeln('- Folder: `$outputPath`')
      ..writeln('- WAV files: ${copied.length}')
      ..writeln()
      ..writeln('## Samples')
      ..writeln();
    for (final region in _regions) {
      final root = region.rootMidi == null
          ? 'none'
          : PolyMultisampleParser.midiToNoteName(region.rootMidi!);
      final range = _rangeBoundsForRegion(region, _regions);
      final rangeText = range == null
          ? 'none'
          : '${PolyMultisampleParser.midiToNoteName(range.start)}-'
                '${PolyMultisampleParser.midiToNoteName(range.end)}';
      buffer.writeln(
        '- `${region.fileName}`: root $root, range $rangeText, '
        'V${region.velocityLayer ?? 1}, RR${region.roundRobin ?? 1}',
      );
    }
    await File(
      p.join(outputPath, '_CUSTOM_BUILD_REPORT.md'),
    ).writeAsString(buffer.toString(), flush: true);
  }

  void _updateLoopFor(PolySampleRegion region, _LoopMarkerDraft markers) {
    setState(() {
      _loopDrafts[region.path] = markers;
      _loopEnabledDrafts[region.path] = true;
      _selectedPath = region.path;
    });
    _refreshLoopPreviewFor(region);
  }

  void _setLoopEnabledFor(PolySampleRegion region, bool enabled) {
    setState(() {
      _loopEnabledDrafts[region.path] = enabled;
      _selectedPath = region.path;
      if (!enabled) {
        _loopPreviewEnabled = false;
      }
    });
    _refreshLoopPreviewFor(region);
  }

  void _updateWavEditFor(PolySampleRegion region, _WavEditDraft draft) {
    setState(() {
      _wavEditDrafts[region.path] = draft;
      _selectedPath = region.path;
    });
    _syncPreviewGainFor(region.path);
    _refreshLoopPreviewFor(region);
  }

  void _setWaveformMode(_WaveformMode mode) {
    setState(() => _waveformMode = mode);
    final path = _playingPath;
    if (path != null) {
      _syncPreviewGainFor(path);
      final selected = _selectedRegion;
      if (selected != null && selected.path == path) {
        _refreshLoopPreviewFor(selected);
      }
    }
  }

  Future<WavOverview?> _loadWaveformFor(PolySampleRegion region) async {
    if (_waveformCache.containsKey(region.path)) {
      return _waveformCache[region.path];
    }
    try {
      final bytes = await _readSampleBytes(region);
      if (bytes == null) {
        return null;
      }
      final overview = WavMetadataReader.parse(bytes);
      _waveformCache[region.path] = overview;
      if (overview != null && !_loopDrafts.containsKey(region.path)) {
        final markers = _LoopMarkerDraft.fromWaveform(overview);
        _loopDrafts[region.path] = markers;
        _savedLoopDrafts[region.path] = markers;
        final hasLoopMetadata =
            overview.loopStart != null && overview.loopEnd != null;
        _loopMetadataPresent[region.path] = hasLoopMetadata;
        _loopEnabledDrafts[region.path] = hasLoopMetadata;
        _wavEditDrafts[region.path] = _WavEditDraft.fromWaveform(overview);
      }
      return overview;
    } catch (_) {
      return null;
    }
  }

  Future<WavOverview?> _waveformFutureFor(PolySampleRegion region) {
    return _waveformFutures.putIfAbsent(
      region.path,
      () => _loadWaveformFor(region),
    );
  }

  bool _isLoopDirty(PolySampleRegion? region) {
    if (region == null || _isNtSdPath(region.path)) return false;
    final draft = _loopDrafts[region.path];
    final saved = _savedLoopDrafts[region.path];
    final hasMetadata = _loopMetadataPresent[region.path] ?? false;
    final loopEnabled = _loopEnabledDrafts[region.path] ?? hasMetadata;
    if (loopEnabled != hasMetadata) return true;
    return loopEnabled && draft != null && saved != null && draft != saved;
  }

  Future<void> _saveLoopFor(PolySampleRegion region) async {
    if (_savingLoop || _isNtSdPath(region.path)) return;
    final overview = await _loadWaveformFor(region);
    if (overview == null) return;
    final loopEnabled =
        _loopEnabledDrafts[region.path] ??
        (overview.loopStart != null && overview.loopEnd != null);
    final markers =
        (_loopDrafts[region.path] ?? _LoopMarkerDraft.fromWaveform(overview))
            .clamped(overview.frameCount)
            .snappedToZeroCrossings(overview);

    setState(() => _savingLoop = true);
    try {
      final file = File(region.path);
      final bytes = await file.readAsBytes();
      final updated = loopEnabled
          ? WavMetadataWriter.writeSmplLoop(
              bytes,
              loopStart: markers.loopStartFrame,
              loopEnd: markers.loopEndFrame,
            )
          : WavMetadataWriter.removeSmplLoop(bytes);
      await file.writeAsBytes(updated, flush: true);
      final refreshed = WavMetadataReader.parse(updated);
      setState(() {
        _waveformCache[region.path] = refreshed ?? overview;
        _loopDrafts[region.path] = markers;
        _savedLoopDrafts[region.path] = markers;
        _loopMetadataPresent[region.path] = loopEnabled;
        _loopEnabledDrafts[region.path] = loopEnabled;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loopEnabled
                  ? 'Saved loop points to WAV metadata.'
                  : 'Removed loop metadata from WAV.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Loop save failed: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _savingLoop = false);
      }
    }
  }

  Future<void> _saveDestructiveWavFor(
    PolySampleRegion region, {
    required bool saveAs,
  }) async {
    if (_renderingWav || _isNtSdPath(region.path)) return;
    final overview = await _loadWaveformFor(region);
    if (overview == null) return;
    final draft =
        (_wavEditDrafts[region.path] ?? _WavEditDraft.fromWaveform(overview))
            .clamped(overview);

    String? targetPath;
    if (saveAs) {
      targetPath = await FilePicker.saveFile(
        dialogTitle: 'Save edited WAV as',
        fileName: p.basename(region.path),
        initialDirectory:
            _existingDirectory(_lastWavExportFolder) ??
            _existingDirectory(p.dirname(region.path)),
        type: FileType.custom,
        allowedExtensions: const ['wav'],
      );
    } else {
      final confirmed = await _confirmOverwriteWav(region);
      if (!confirmed) return;
      targetPath = region.path;
    }
    final target = targetPath;
    if (target == null) return;
    if (saveAs) {
      unawaited(_saveWavExportFolder(target));
    }

    setState(() => _renderingWav = true);
    try {
      final bytes = await File(region.path).readAsBytes();
      final rendered = WavAudioRenderer.render(
        bytes,
        draft.toRenderOptions(overview),
      );
      await File(target).writeAsBytes(rendered, flush: true);
      final refreshed = WavMetadataReader.parse(rendered);
      setState(() {
        if (target == region.path) {
          _waveformCache[region.path] = refreshed ?? overview;
          _loopDrafts[region.path] = _LoopMarkerDraft.fromWaveform(
            refreshed ?? overview,
          );
          _savedLoopDrafts[region.path] = _loopDrafts[region.path]!;
          _loopMetadataPresent[region.path] =
              (refreshed ?? overview).loopStart != null &&
              (refreshed ?? overview).loopEnd != null;
          _loopEnabledDrafts[region.path] =
              _loopMetadataPresent[region.path] ?? false;
          _wavEditDrafts[region.path] = _WavEditDraft.fromWaveform(
            refreshed ?? overview,
          );
        } else {
          final newRegion = PolyMultisampleParser.parseFile(
            File(target),
            basePath: widget.instrument.sourcePath,
          );
          _regions.add(newRegion);
          PolyMultisampleFolderReader.sortRegions(_regions);
          _baselineRegions.add(newRegion);
          PolyMultisampleFolderReader.sortRegions(_baselineRegions);
          _mapLanes = _sortedSampleLanes(_regions);
          _mapMinMidi = _initialMapMinMidi(_regions);
          _mapMaxMidi = _initialMapMaxMidi(_regions, _mapMinMidi);
          _mapRevision++;
          _selectedPath = newRegion.path;
          if (refreshed != null) {
            _waveformCache[newRegion.path] = refreshed;
            _loopDrafts[newRegion.path] = _LoopMarkerDraft.fromWaveform(
              refreshed,
            );
            _savedLoopDrafts[newRegion.path] = _loopDrafts[newRegion.path]!;
            _loopMetadataPresent[newRegion.path] =
                refreshed.loopStart != null && refreshed.loopEnd != null;
            _loopEnabledDrafts[newRegion.path] =
                _loopMetadataPresent[newRegion.path] ?? false;
            _wavEditDrafts[newRegion.path] = _WavEditDraft.fromWaveform(
              refreshed,
            );
          }
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(saveAs ? 'Saved WAV as.' : 'Saved WAV.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('WAV save failed: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _renderingWav = false);
      }
    }
  }

  Future<bool> _confirmOverwriteWav(PolySampleRegion region) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Overwrite WAV?'),
        content: Text(
          'This will rewrite ${region.fileName}. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Overwrite'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<Uint8List?> _readSampleBytes(PolySampleRegion region) async {
    if (region.path.startsWith('/')) {
      final manager = context.read<DistingCubit>().disting();
      return manager?.requestFileDownload(region.path);
    }
    return File(region.path).readAsBytes();
  }

  Future<void> _toggleSamplePlayback(PolySampleRegion region) async {
    if (_isNtSdPath(region.path)) return;
    if (_playingPath == region.path && _playerPlaying) {
      await _samplePlayer.setReleaseMode(ReleaseMode.release);
      await _samplePlayer.stop();
      _clearLoopPreviewFile();
      return;
    }
    await _playSamplePreview(region);
  }

  Future<void> _playSamplePreview(PolySampleRegion region) async {
    if (_isNtSdPath(region.path)) return;
    final overview = await _loadWaveformFor(region);
    if (overview == null) return;
    final markers =
        _loopDrafts[region.path] ?? _LoopMarkerDraft.fromWaveform(overview);
    await _samplePlayer.stop();
    _clearLoopPreviewFile();
    await _samplePlayer.setVolume(_previewGainLinear);
    var sourcePath = region.path;
    if (_loopPreviewEnabled) {
      final loopPath = _waveformMode == _WaveformMode.destructive
          ? await _writeDestructivePreviewFile(region, overview)
          : await _writeLoopPreviewFile(region, overview, markers);
      if (loopPath != null) {
        sourcePath = loopPath;
        await _samplePlayer.setReleaseMode(ReleaseMode.loop);
      } else {
        await _samplePlayer.setReleaseMode(ReleaseMode.release);
      }
    } else {
      await _samplePlayer.setReleaseMode(ReleaseMode.release);
    }
    await _samplePlayer.play(DeviceFileSource(sourcePath));
    if (!mounted) return;
    setState(() {
      _playingPath = region.path;
      _playerPlaying = true;
    });
  }

  void _syncPreviewGainFor(String path) {
    if (_playingPath != path || !_playerPlaying) return;
    unawaited(_samplePlayer.setVolume(_previewGainLinear));
  }

  double get _previewGainLinear {
    return math.pow(10, _previewGainDb / 20).toDouble().clamp(0.0, 2.0);
  }

  void _setPreviewGainDb(double value) {
    setState(() => _previewGainDb = value);
    final path = _playingPath;
    if (path != null) {
      _syncPreviewGainFor(path);
    }
  }

  Future<void> _setLoopPreview(bool enabled) async {
    final selected = _selectedRegion;
    setState(() => _loopPreviewEnabled = enabled);
    if (!enabled) {
      await _samplePlayer.setReleaseMode(ReleaseMode.release);
      if (selected != null && _playingPath == selected.path && _playerPlaying) {
        await _playSamplePreview(selected);
      } else {
        _clearLoopPreviewFile();
      }
      return;
    }
    if (selected == null || _playingPath != selected.path) return;
    if (_playerPlaying) {
      await _playSamplePreview(selected);
    }
  }

  void _refreshLoopPreviewFor(PolySampleRegion region) {
    if (!_loopPreviewEnabled || _playingPath != region.path) {
      return;
    }
    unawaited(_playSamplePreview(region));
  }

  Future<String?> _writeLoopPreviewFile(
    PolySampleRegion region,
    WavOverview overview,
    _LoopMarkerDraft markers,
  ) async {
    final loop = markers.clamped(overview.frameCount);
    if (loop.loopEndFrame <= loop.loopStartFrame) return null;
    final bytes = await _readSampleBytes(region);
    if (bytes == null) return null;
    final rendered = WavAudioRenderer.render(
      bytes,
      WavRenderOptions(
        trimStartFrame: loop.loopStartFrame,
        trimEndFrame: loop.loopEndFrame,
      ),
    );
    final dir = Directory(
      p.join(Directory.systemTemp.path, 'nt_helper_loop_preview'),
    );
    await dir.create(recursive: true);
    final safeName = p.basenameWithoutExtension(region.fileName);
    final file = File(
      p.join(
        dir.path,
        '${safeName}_${DateTime.now().microsecondsSinceEpoch}.wav',
      ),
    );
    await file.writeAsBytes(rendered, flush: true);
    _loopPreviewFilePath = file.path;
    return file.path;
  }

  Future<String?> _writeDestructivePreviewFile(
    PolySampleRegion region,
    WavOverview overview,
  ) async {
    final bytes = await _readSampleBytes(region);
    if (bytes == null) return null;
    final draft =
        (_wavEditDrafts[region.path] ?? _WavEditDraft.fromWaveform(overview))
            .clamped(overview);
    final rendered = WavAudioRenderer.render(
      bytes,
      draft.toRenderOptions(overview),
    );
    final dir = Directory(
      p.join(Directory.systemTemp.path, 'nt_helper_loop_preview'),
    );
    await dir.create(recursive: true);
    final safeName = p.basenameWithoutExtension(region.fileName);
    final file = File(
      p.join(
        dir.path,
        '${safeName}_destructive_${DateTime.now().microsecondsSinceEpoch}.wav',
      ),
    );
    await file.writeAsBytes(rendered, flush: true);
    _loopPreviewFilePath = file.path;
    return file.path;
  }

  void _clearLoopPreviewFile() {
    final path = _loopPreviewFilePath;
    _loopPreviewFilePath = null;
    if (path == null) return;
    try {
      File(path).deleteSync();
    } catch (_) {
      // Best-effort cleanup only.
    }
  }

  Future<void> _openSampleFolder(PolySampleRegion region) async {
    if (_isNtSdPath(region.path)) return;
    final dir = p.dirname(region.path);
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      } else {
        await Process.run('xdg-open', [dir]);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open folder: $e')));
    }
  }

  void _updateRootFor(PolySampleRegion region, int value) {
    final updated = _updateRoot(region, value);
    setState(() {
      final paths = _roundRobinSiblings(
        region,
        _regions,
      ).map((candidate) => candidate.path).toSet();
      for (var index = 0; index < _regions.length; index++) {
        if (!paths.contains(_regions[index].path)) continue;
        _regions[index] = _regions[index].copyWith(
          rootMidi: updated.rootMidi,
          rootName: updated.rootName,
        );
      }
      _mapRevision++;
      _selectedPath = region.path;
    });
    final selected = _selectedRegion;
    if (selected != null) {
      widget.onSelectRegion(selected);
    }
  }

  void _updateVelocityFor(PolySampleRegion region, int value) {
    setState(() {
      final paths = _roundRobinSiblings(
        region,
        _regions,
      ).map((candidate) => candidate.path).toSet();
      for (var index = 0; index < _regions.length; index++) {
        if (!paths.contains(_regions[index].path)) continue;
        _regions[index] = _regions[index].copyWith(velocityLayer: value);
      }
      _ensureMapLanes();
      _mapRevision++;
      _selectedPath = region.path;
    });
    final selected = _selectedRegion;
    if (selected != null) {
      widget.onSelectRegion(selected);
    }
  }

  void _updateRangeLowFor(PolySampleRegion region, int value) {
    setState(() {
      final snapshot = List<PolySampleRegion>.of(_regions);
      final current = _regionInSnapshot(region, snapshot);
      if (current == null) return;
      final currentLow = _effectiveLow(current);
      if (currentLow == null) return;
      final min = _lowMinFor(current, snapshot);
      final max = _lowMaxFor(current, snapshot);
      final nextLow = value.clamp(min, max).toInt();
      final paths = _roundRobinSiblings(
        current,
        snapshot,
      ).map((candidate) => candidate.path).toSet();
      for (var index = 0; index < _regions.length; index++) {
        if (!paths.contains(_regions[index].path)) continue;
        _regions[index] = _regions[index].copyWith(switchPoint: nextLow);
      }
      _mapRevision++;
      _selectedPath = region.path;
    });
    final selected = _selectedRegion;
    if (selected != null) {
      widget.onSelectRegion(selected);
    }
  }

  void _updateRangeHighFor(PolySampleRegion region, int value) {
    setState(() {
      final snapshot = List<PolySampleRegion>.of(_regions);
      final current = _regionInSnapshot(region, snapshot);
      if (current == null) return;
      final next = _nextRegionInLane(current, snapshot);
      if (next == null) return;
      final afterNext = _nextRegionInLane(next, snapshot);
      final currentLow = _effectiveLow(current);
      if (currentLow == null) return;
      final maxNextLow = afterNext == null
          ? 127
          : math.max(currentLow + 1, _effectiveLow(afterNext)! - 1);
      final nextLow = (value + 1).clamp(currentLow + 1, maxNextLow).toInt();
      final paths = _roundRobinSiblings(
        next,
        snapshot,
      ).map((candidate) => candidate.path).toSet();
      for (var index = 0; index < _regions.length; index++) {
        if (!paths.contains(_regions[index].path)) continue;
        _regions[index] = _regions[index].copyWith(switchPoint: nextLow);
      }
      _mapRevision++;
      _selectedPath = region.path;
    });
    final selected = _selectedRegion;
    if (selected != null) {
      widget.onSelectRegion(selected);
    }
  }

  bool get _hasDraftChanges {
    if (widget.isCustomDraft) return false;
    final currentPaths = {for (final region in _regions) region.path};
    if (_baselineRegions.any((region) => !currentPaths.contains(region.path))) {
      return true;
    }
    final original = {
      for (final region in _baselineRegions) region.path: region,
    };
    for (final region in _regions) {
      final before = original[region.path];
      if (before == null) return true;
      if (before.rootMidi != region.rootMidi ||
          before.switchPoint != region.switchPoint ||
          (before.velocityLayer ?? 1) != (region.velocityLayer ?? 1) ||
          (before.roundRobin ?? 1) != (region.roundRobin ?? 1)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _applyDraft() async {
    if (_applying || !_hasDraftChanges) return;
    setState(() => _applying = true);
    try {
      final removals = _buildRemovePlan(_baselineRegions, _regions);
      final additions = _buildAddPlan(
        _baselineRegions,
        _regions,
        widget.instrument.sourcePath,
      );
      final changes = _buildRenamePlan(_baselineRegions, _regions);
      if (changes.isEmpty && removals.isEmpty && additions.isEmpty) {
        setState(() => _baselineRegions = List<PolySampleRegion>.of(_regions));
        return;
      }

      final hasNtPath =
          changes.values.any((change) => _isNtSdPath(change.source.path)) ||
          removals.any((region) => _isNtSdPath(region.path)) ||
          additions.values.any((change) => _isNtSdPath(change.targetPath));
      if (hasNtPath) {
        final manager = context.read<DistingCubit>().disting();
        if (manager == null) {
          throw Exception('Connect to Disting NT before applying SD changes.');
        }
        await _applyNtDeletes(manager, removals);
        await _applyNtRenames(manager, changes.values.toList());
        await _applyNtAdds(manager, additions);
      } else {
        await _applyLocalDeletes(removals);
        await _applyLocalRenames(changes.values.toList());
        await _applyLocalAdds(additions);
      }

      final updatedRegions = _regions
          .map(
            (region) =>
                changes[region.path]?.updated ??
                additions[region.path]?.updated ??
                region,
          )
          .toList();
      final selectedPath = _selectedPath;
      final currentPaths = {for (final region in updatedRegions) region.path};
      for (final change in changes.values) {
        if (_waveformCache.containsKey(change.source.path)) {
          _waveformCache[change.updated.path] = _waveformCache.remove(
            change.source.path,
          );
        }
        _waveformFutures.remove(change.source.path);
        if (_loopDrafts.containsKey(change.source.path)) {
          _loopDrafts[change.updated.path] = _loopDrafts.remove(
            change.source.path,
          )!;
        }
        if (_savedLoopDrafts.containsKey(change.source.path)) {
          _savedLoopDrafts[change.updated.path] = _savedLoopDrafts.remove(
            change.source.path,
          )!;
        }
        if (_loopMetadataPresent.containsKey(change.source.path)) {
          _loopMetadataPresent[change.updated.path] = _loopMetadataPresent
              .remove(change.source.path)!;
        }
        if (_loopEnabledDrafts.containsKey(change.source.path)) {
          _loopEnabledDrafts[change.updated.path] = _loopEnabledDrafts.remove(
            change.source.path,
          )!;
        }
        if (_wavEditDrafts.containsKey(change.source.path)) {
          _wavEditDrafts[change.updated.path] = _wavEditDrafts.remove(
            change.source.path,
          )!;
        }
      }
      setState(() {
        _regions = updatedRegions;
        _baselineRegions = List<PolySampleRegion>.of(updatedRegions);
        _mapLanes = _sortedSampleLanes(_regions);
        _mapRevision++;
        _selectedPath =
            selectedPath == null || !currentPaths.contains(selectedPath)
            ? (_regions.isEmpty ? null : _regions.first.path)
            : changes[selectedPath]?.updated.path ?? selectedPath;
        _selectedPaths = _selectedPath == null ? {} : {_selectedPath!};
        _playingPath =
            _playingPath == null || !currentPaths.contains(_playingPath)
            ? null
            : changes[_playingPath]?.updated.path ?? _playingPath;
      });
      if (mounted) {
        final summary = <String>[
          if (changes.isNotEmpty) '${changes.length} rename(s)',
          if (additions.isNotEmpty) '${additions.length} addition(s)',
          if (removals.isNotEmpty) '${removals.length} removal(s)',
        ].join(' and ');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Applied $summary.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Apply failed: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _applying = false);
      }
    }
  }

  void _discardDraft() {
    setState(() {
      _resetDraft();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = _selectedRegion;
    final instrument = widget.instrument.copyWith(regions: _regions);

    return Column(
      children: [
        SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _StatChip(
                          label: 'Files',
                          value: instrument.regions.length.toString(),
                        ),
                        const SizedBox(width: 8),
                        _StatChip(
                          label: 'Mapped',
                          value: instrument.mappedCount.toString(),
                        ),
                        const SizedBox(width: 8),
                        _StatChip(
                          label: 'Vel Layers',
                          value: instrument.velocityLayers.length.toString(),
                        ),
                        const SizedBox(width: 8),
                        _StatChip(
                          label: 'Warnings',
                          value: instrument.warningCount.toString(),
                          warning: instrument.warningCount > 0,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          instrument.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _DraftStatusChip(dirty: _hasDraftChanges),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _addCustomWavs,
                  icon: const Icon(Icons.audio_file, size: 18),
                  label: const Text('Add files'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _addCustomFolder,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Add folder'),
                ),
                const SizedBox(width: 8),
                if (widget.isCustomDraft) ...[
                  OutlinedButton.icon(
                    onPressed: _regions.isEmpty || _applying
                        ? null
                        : () => _saveCustomDraft(saveAs: true),
                    icon: const Icon(Icons.save_as, size: 18),
                    label: const Text('Save as'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed:
                        _regions.isEmpty ||
                            _applying ||
                            _lastCustomOutputFolder == null
                        ? null
                        : () => _saveCustomDraft(saveAs: false),
                    icon: const Icon(Icons.save, size: 18),
                    label: Text(_applying ? 'Saving...' : 'Save'),
                  ),
                  const SizedBox(width: 8),
                ],
                OutlinedButton.icon(
                  onPressed: _selectedPaths.isEmpty || _regions.isEmpty
                      ? null
                      : _removeSelectedRegions,
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  label: Text(
                    _selectedPaths.length > 1
                        ? 'Remove ${_selectedPaths.length}'
                        : 'Remove',
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  avatar: const Icon(Icons.volume_up, size: 16),
                  label: const Text('Auto preview'),
                  selected: _autoPreviewOnSelect,
                  onSelected: (value) =>
                      setState(() => _autoPreviewOnSelect = value),
                ),
                const SizedBox(width: 8),
                _PreviewGainControl(
                  valueDb: _previewGainDb,
                  onChanged: _setPreviewGainDb,
                ),
                const SizedBox(width: 8),
                if (!widget.isCustomDraft) ...[
                  OutlinedButton.icon(
                    onPressed: _hasDraftChanges && !_applying
                        ? _discardDraft
                        : null,
                    icon: const Icon(Icons.undo, size: 18),
                    label: const Text('Discard'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _hasDraftChanges && !_applying
                        ? _applyDraft
                        : null,
                    icon: const Icon(Icons.save, size: 18),
                    label: Text(_applying ? 'Applying...' : 'Apply'),
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    children: [
                      _KeyMapSection(
                        instrument: instrument,
                        selected: selected,
                        lanes: _mapLanes,
                        minMidi: _mapMinMidi,
                        maxMidi: _mapMaxMidi,
                        mapRevision: _mapRevision,
                        onSelectRegion: _selectRegion,
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: _SampleList(
                          regions: instrument.regions,
                          selected: selected,
                          selectedPaths: _selectedPaths,
                          onSelectRegion: _selectRegion,
                          onSelectRegionFromList: _selectRegionFromList,
                          onChangeRegion: _updateRegion,
                          onChangeRoot: _updateRootFor,
                          onChangeVelocity: _updateVelocityFor,
                          onChangeLow: _updateRangeLowFor,
                          onChangeHigh: _updateRangeHighFor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              VerticalDivider(width: 1, color: colorScheme.outlineVariant),
              SizedBox(
                width: 340,
                child: _SampleInspector(
                  region: selected,
                  regions: instrument.regions,
                  waveform: selected == null || _isNtSdPath(selected.path)
                      ? null
                      : _waveformFutureFor(selected),
                  cachedWaveform: selected == null
                      ? null
                      : _waveformCache[selected.path],
                  canPreviewAudio:
                      selected != null && !_isNtSdPath(selected.path),
                  isPreviewPlaying:
                      selected != null &&
                      _playingPath == selected.path &&
                      _playerPlaying,
                  loopPreviewEnabled: _loopPreviewEnabled,
                  waveformMessage:
                      selected != null && _isNtSdPath(selected.path)
                      ? 'Waveform, audio preview, and loop-point editing need a local or mounted SD folder. Direct NT SD files cannot be previewed over MIDI.'
                      : null,
                  loopDraft: selected == null
                      ? null
                      : _loopDrafts[selected.path],
                  loopEnabled: selected == null
                      ? false
                      : _loopEnabledDrafts[selected.path] ??
                            (_loopMetadataPresent[selected.path] ?? false),
                  loopDirty: _isLoopDirty(selected),
                  savingLoop: _savingLoop,
                  wavEditDraft: selected == null
                      ? null
                      : _wavEditDrafts[selected.path],
                  waveformMode: _waveformMode,
                  renderingWav: _renderingWav,
                  onChangeLoop: _updateLoopFor,
                  onChangeLoopEnabled: _setLoopEnabledFor,
                  onChangeWavEdit: _updateWavEditFor,
                  onChangeWaveformMode: _setWaveformMode,
                  onSelectRegion: _selectRegion,
                  onChooseFolder: widget.onChooseFolder,
                  onRevealFolder: selected == null || _isNtSdPath(selected.path)
                      ? null
                      : () => _openSampleFolder(selected),
                  onSaveLoop: selected == null
                      ? null
                      : () => _saveLoopFor(selected),
                  onSaveWav: selected == null
                      ? null
                      : () => _saveDestructiveWavFor(selected, saveAs: false),
                  onSaveWavAs: selected == null
                      ? null
                      : () => _saveDestructiveWavFor(selected, saveAs: true),
                  onTogglePreview: _toggleSamplePlayback,
                  onToggleLoopPreview: _setLoopPreview,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

bool _isNtSdPath(String path) => path.startsWith('/');

bool _isIgnoredSampleSidecar(String name) {
  return name == '.DS_Store' || name.startsWith('._');
}

int _naturalCompare(String a, String b) {
  final chunks = RegExp(r'\d+|\D+');
  final aParts = chunks.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final bParts = chunks.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  final count = math.min(aParts.length, bParts.length);
  for (var i = 0; i < count; i++) {
    final aNumber = int.tryParse(aParts[i]);
    final bNumber = int.tryParse(bParts[i]);
    final result = aNumber != null && bNumber != null
        ? aNumber.compareTo(bNumber)
        : aParts[i].compareTo(bParts[i]);
    if (result != 0) return result;
  }
  return aParts.length.compareTo(bParts.length);
}

Future<List<PolySampleRegion>> _pickSelectedDecentWavs(
  BuildContext context,
  String sourcePath,
) async {
  final groups = await _decentWavGroups(sourcePath);
  return _pickSelectedWavGroups(context, groups);
}

Future<List<PolySampleRegion>> _pickSelectedWavGroups(
  BuildContext context,
  List<_DecentWavGroup> groups,
) async {
  final candidates = groups.expand((group) => group.candidates).toList();
  if (!context.mounted || candidates.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No WAV files found in that source.')),
      );
    }
    return const [];
  }
  final result = await showDialog<_DecentWavSelectionResult>(
    context: context,
    builder: (context) => _DecentWavSelectionDialog(groups: groups),
  );
  if (result == null || result.selected.isEmpty) return const [];

  final regions = <PolySampleRegion>[];
  final sorted = result.selected.toList()
    ..sort((a, b) => _naturalCompare(a.label, b.label));
  for (var index = 0; index < sorted.length; index++) {
    final candidate = sorted[index];
    final file = await candidate.materialize();
    regions.add(
      candidate.toRegion(
        file,
        mappingMode: result.mappingMode,
        spreadRootMidi: (result.spreadStartMidi + index).clamp(0, 127).toInt(),
        stackRootMidi: result.stackRootMidi,
        stackLowMidi: result.stackLowMidi,
        stackVelocityLayer: result.stackVelocityLayer,
        stackRoundRobin: index + 1,
      ),
    );
  }
  return regions;
}

String _commonParentPath(List<File> files) {
  if (files.isEmpty) return '.';
  final dirs = files.map((file) => p.dirname(file.path)).toList();
  var common = p.split(dirs.first);
  for (final dir in dirs.skip(1)) {
    final parts = p.split(dir);
    var length = 0;
    while (length < common.length &&
        length < parts.length &&
        common[length].toLowerCase() == parts[length].toLowerCase()) {
      length++;
    }
    common = common.take(length).toList();
    if (common.isEmpty) return p.dirname(files.first.path);
  }
  return common.isEmpty ? p.dirname(files.first.path) : p.joinAll(common);
}

Future<List<_DecentWavGroup>> _decentWavGroups(String sourcePath) async {
  final sourceDir = Directory(sourcePath);
  if (await sourceDir.exists()) {
    final presets = <File>[];
    final rawWavs = <File>[];
    await for (final entity in sourceDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (_isIgnoredSampleSidecar(name)) continue;
      final extension = p.extension(name).toLowerCase();
      if (extension == '.dspreset') {
        presets.add(entity);
      } else if (extension == '.wav') {
        rawWavs.add(entity);
      }
    }
    presets.sort(
      (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
    );
    if (presets.isNotEmpty) {
      final groups = <_DecentWavGroup>[];
      for (final preset in presets) {
        groups.addAll(
          await _groupsFromLocalDspreset(
            preset,
            prefixName: presets.length > 1,
          ),
        );
      }
      if (groups.isNotEmpty) return groups;
    }
    return _groupsFromLocalWavs(rawWavs, sourceDir.path);
  }

  final extension = p.extension(sourcePath).toLowerCase();
  if (extension == '.dspreset') {
    return _groupsFromLocalDspreset(File(sourcePath));
  }
  if (extension == '.zip' || extension == '.dslibrary') {
    return _groupsFromArchive(File(sourcePath));
  }
  return const [];
}

Future<List<_DecentWavGroup>> _groupsFromLocalDspreset(
  File preset, {
  bool prefixName = false,
}) async {
  final content = await preset.readAsString();
  return _groupsFromDecentXml(
    content,
    presetName: p.basenameWithoutExtension(preset.path),
    prefixName: prefixName,
    makeCandidate: (samplePath, groupLabel, mapping) async {
      final file = File(p.normalize(p.join(preset.parent.path, samplePath)));
      if (!await file.exists()) return null;
      return _LocalDecentWavCandidate(
        file: file,
        label: samplePath,
        groupLabel: groupLabel,
        mapping: mapping,
      );
    },
  );
}

Future<List<_DecentWavGroup>> _groupsFromArchive(File archiveFile) async {
  final archive = ZipDecoder().decodeBytes(await archiveFile.readAsBytes());
  final files = <String, ArchiveFile>{};
  final filesByLowerPath = <String, ArchiveFile>{};
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final name = entry.name.replaceAll('\\', '/');
    if (_isMacOsArchiveJunkPath(name)) continue;
    final normalized = _normalizeArchivePath(name);
    files[normalized] = entry;
    filesByLowerPath[normalized.toLowerCase()] = entry;
  }
  final presets =
      files.entries
          .where(
            (entry) =>
                p.posix.extension(entry.key).toLowerCase() == '.dspreset',
          )
          .toList()
        ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  if (presets.isNotEmpty) {
    final groups = <_DecentWavGroup>[];
    for (final preset in presets) {
      final bytes = preset.value.content as List<int>;
      groups.addAll(
        await _groupsFromDecentXml(
          utf8.decode(bytes, allowMalformed: true),
          presetName: p.posix.basenameWithoutExtension(preset.key),
          prefixName: presets.length > 1,
          makeCandidate: (samplePath, groupLabel, mapping) async {
            final resolved = _resolveArchiveSamplePath(preset.key, samplePath);
            final direct = _normalizeArchivePath(samplePath);
            final entry =
                files[resolved] ??
                files[direct] ??
                filesByLowerPath[resolved.toLowerCase()] ??
                filesByLowerPath[direct.toLowerCase()];
            if (entry == null) return null;
            return _ArchiveDecentWavCandidate(
              sourceName: p.basenameWithoutExtension(archiveFile.path),
              entry: entry,
              label: samplePath,
              groupLabel: groupLabel,
              mapping: mapping,
            );
          },
        ),
      );
    }
    if (groups.isNotEmpty) return groups;
  }
  final wavs = files.entries
      .where((entry) => p.posix.extension(entry.key).toLowerCase() == '.wav')
      .map(
        (entry) => _ArchiveDecentWavCandidate(
          sourceName: p.basenameWithoutExtension(archiveFile.path),
          entry: entry.value,
          label: entry.key,
          groupLabel: p.posix.dirname(entry.key),
        ),
      )
      .toList();
  return _groupsFromCandidates(wavs);
}

Future<List<_DecentWavGroup>> _groupsFromDecentXml(
  String content, {
  required String presetName,
  required bool prefixName,
  required Future<_DecentWavCandidate?> Function(
    String samplePath,
    String groupLabel,
    _DecentSampleMapping mapping,
  )
  makeCandidate,
}) async {
  final doc = html_parser.parse(content);
  var groupElements = doc.querySelectorAll('group');
  if (groupElements.isEmpty) {
    groupElements = [doc.body ?? doc.documentElement!];
  }
  final groups = <_DecentWavGroup>[];
  for (var index = 0; index < groupElements.length; index++) {
    final group = groupElements[index];
    final samples = group.querySelectorAll('sample');
    if (samples.isEmpty) continue;
    final rawLabel = _decentGroupLabel(group, index);
    final label = prefixName ? '$presetName / $rawLabel' : rawLabel;
    final mappings = _decentSampleMappings(group, samples);
    final candidates = <_DecentWavCandidate>[];
    for (final mapping in mappings) {
      final samplePath = mapping.path;
      if (samplePath == null) continue;
      final candidate = await makeCandidate(samplePath, label, mapping);
      if (candidate != null) candidates.add(candidate);
    }
    if (candidates.isEmpty) continue;
    candidates.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    groups.add(
      _DecentWavGroup(
        label: label,
        detail: _groupDetail(candidates),
        candidates: candidates,
      ),
    );
  }
  groups.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return groups;
}

List<_DecentSampleMapping> _decentSampleMappings(
  html_dom.Element group,
  List<html_dom.Element> samples,
) {
  final groupAttrs = _decentAttrs(group);
  final groupVelocityLow = _parseDecentInt(groupAttrs['lovel']);
  final groupVelocityHigh = _parseDecentInt(groupAttrs['hivel']);
  final groupSeqPosition = _parseDecentInt(groupAttrs['seqposition']);
  final raw = <_DecentSampleMapping>[];

  for (final sample in samples) {
    final attrs = _decentAttrs(sample);
    final path = _firstDecentAttr(attrs, const [
      'path',
      'filename',
      'file',
      'sample',
    ])?.replaceAll('\\', '/');
    final root = _parseDecentNote(
      _firstDecentAttr(attrs, const [
        'rootnote',
        'pitchkeycenter',
        'pitch_keycenter',
        'keycenter',
      ]),
    );
    final low = _parseDecentNote(
      _firstDecentAttr(attrs, const ['lonote', 'lokey', 'lowkey']),
    );
    final velocityLow = _parseDecentInt(attrs['lovel']) ?? groupVelocityLow;
    final velocityHigh = _parseDecentInt(attrs['hivel']) ?? groupVelocityHigh;
    raw.add(
      _DecentSampleMapping(
        path: path,
        rootMidi: root,
        switchPoint: low ?? root,
        velocityLow: velocityLow?.clamp(1, 127).toInt(),
        velocityHigh: velocityHigh?.clamp(1, 127).toInt(),
        seqPosition: _parseDecentInt(attrs['seqposition']) ?? groupSeqPosition,
        loopStart: _parseDecentInt(attrs['loopstart']),
        loopEnd: _parseDecentInt(attrs['loopend']),
      ),
    );
  }

  final velocityRanges =
      raw
          .where(
            (mapping) =>
                mapping.velocityLow != null || mapping.velocityHigh != null,
          )
          .map(
            (mapping) =>
                '${mapping.velocityLow ?? 1}-${mapping.velocityHigh ?? 127}',
          )
          .toSet()
          .toList()
        ..sort((a, b) {
          final aLow = int.tryParse(a.split('-').first) ?? 1;
          final bLow = int.tryParse(b.split('-').first) ?? 1;
          return aLow.compareTo(bLow);
        });
  final velocityLayerByRange = {
    for (var i = 0; i < velocityRanges.length; i++) velocityRanges[i]: i + 1,
  };
  return raw.map((mapping) {
    final velocityKey =
        '${mapping.velocityLow ?? 1}-${mapping.velocityHigh ?? 127}';
    final velocityLayer = velocityLayerByRange[velocityKey] ?? 1;
    final requestedRoundRobin = mapping.seqPosition;
    final assignedRoundRobin =
        requestedRoundRobin != null && requestedRoundRobin > 0
        ? requestedRoundRobin
        : 1;
    return mapping.copyWith(
      velocityLayer: velocityLayer,
      roundRobin: assignedRoundRobin,
    );
  }).toList();
}

List<_DecentWavGroup> _groupsFromLocalWavs(List<File> files, String basePath) {
  final candidates = files.map((file) {
    final label = p.relative(file.path, from: basePath);
    final groupLabel = p.dirname(label) == '.'
        ? 'Loose WAVs'
        : p.dirname(label);
    return _LocalDecentWavCandidate(
      file: file,
      label: label,
      groupLabel: groupLabel,
    );
  }).toList();
  return _groupsFromCandidates(candidates);
}

List<_DecentWavGroup> _groupsFromCandidates(
  List<_DecentWavCandidate> candidates,
) {
  final byGroup = <String, List<_DecentWavCandidate>>{};
  for (final candidate in candidates) {
    byGroup.putIfAbsent(candidate.groupLabel, () => []).add(candidate);
  }
  final groups = byGroup.entries.map((entry) {
    final groupCandidates = entry.value
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return _DecentWavGroup(
      label: entry.key,
      detail: _groupDetail(groupCandidates),
      candidates: groupCandidates,
    );
  }).toList();
  groups.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return groups;
}

String _groupDetail(List<_DecentWavCandidate> candidates) {
  final examples = candidates
      .take(2)
      .map((candidate) => p.basename(candidate.label))
      .join(', ');
  return '${candidates.length} WAV${candidates.length == 1 ? '' : 's'}'
      '${_roundRobinDetail(candidates)}'
      '${examples.isEmpty ? '' : ' · e.g. $examples'}';
}

String _roundRobinDetail(List<_DecentWavCandidate> candidates) {
  final rrValues = candidates
      .map((candidate) => candidate.mapping.seqPosition)
      .whereType<int>()
      .toList();
  if (rrValues.isEmpty) return '';
  rrValues.sort();
  final first = rrValues.first;
  final last = rrValues.last;
  final summary = first == last ? 'RR $first' : 'RR $first-$last';
  return ' · $summary from Decent seqPosition';
}

Map<String, String> _decentAttrs(html_dom.Element element) {
  return {
    for (final entry in element.attributes.entries)
      entry.key.toString().toLowerCase(): entry.value.trim(),
  };
}

String? _firstDecentAttr(Map<String, String> attrs, List<String> keys) {
  for (final key in keys) {
    final value = attrs[key];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

String _decentGroupLabel(html_dom.Element group, int index) {
  final attrs = _decentAttrs(group);
  for (final key in const [
    'name',
    'label',
    'tags',
    'tag',
    'articulation',
    'mic',
  ]) {
    final value = attrs[key];
    if (value != null && value.isNotEmpty) return value;
  }
  final interesting = <String>[];
  for (final key in const [
    'seqmode',
    'seqposition',
    'volume',
    'lovel',
    'hivel',
  ]) {
    final value = attrs[key];
    if (value != null && value.isNotEmpty) {
      interesting.add('$key=$value');
    }
  }
  return interesting.isEmpty ? 'Group ${index + 1}' : interesting.join(', ');
}

int? _parseDecentInt(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return int.tryParse(value.trim());
}

int? _parseDecentNote(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final trimmed = value.trim();
  return int.tryParse(trimmed) ?? PolyMultisampleParser.noteNameToMidi(trimmed);
}

String _normalizeArchivePath(String path) {
  final normalized = p.posix.normalize(path.replaceAll('\\', '/'));
  return normalized.replaceFirst(RegExp(r'^/+'), '');
}

String _resolveArchiveSamplePath(String presetPath, String samplePath) {
  final presetDir = p.posix.dirname(presetPath);
  final base = presetDir == '.' ? '' : presetDir;
  final cleanSamplePath = _normalizeArchivePath(samplePath);
  return _normalizeArchivePath(p.posix.join(base, cleanSamplePath));
}

bool _isMacOsArchiveJunkPath(String path) {
  final parts = path.split('/');
  return parts.any(
    (part) =>
        part == '__MACOSX' || part == '.DS_Store' || part.startsWith('._'),
  );
}

PolySampleRegion _customRegionFromFile(
  File file, {
  String? basePath,
  String? displayName,
}) {
  final fileName = p.basename(file.path);
  final resolvedDisplayName =
      displayName ??
      (basePath == null ? fileName : p.relative(file.path, from: basePath));
  return PolySampleRegion(
    path: file.path,
    fileName: fileName,
    displayName: resolvedDisplayName,
    velocityLayer: 1,
    roundRobin: 1,
    issues: const [PolySampleIssue.missingRootNote],
  );
}

PolySampleRegion _mappedRegionFromFile(
  File file, {
  required String displayName,
  required int rootMidi,
  int? switchPoint,
  int velocityLayer = 1,
  int roundRobin = 1,
  int? loopStart,
  int? loopEnd,
}) {
  final region = PolySampleRegion(
    path: file.path,
    fileName: p.basename(file.path),
    displayName: displayName,
    rootMidi: rootMidi,
    rootName: PolyMultisampleParser.midiToNoteName(rootMidi),
    switchPoint: switchPoint ?? rootMidi,
    velocityLayer: velocityLayer,
    roundRobin: roundRobin,
    loopStart: loopStart,
    loopEnd: loopEnd,
  );
  return region.copyWithIssues(region.currentIssues);
}

PolySampleRegion _detectedRegionFromFile(
  File file, {
  required String displayName,
  _DecentSampleMapping mapping = const _DecentSampleMapping(),
}) {
  final detected = PolyMultisampleParser.parsePath(displayName);
  final root = detected.rootMidi;
  if (root == null) {
    return _customRegionFromFile(file, displayName: displayName);
  }
  return _mappedRegionFromFile(
    file,
    displayName: displayName,
    rootMidi: root,
    switchPoint: detected.switchPoint ?? mapping.switchPoint ?? root,
    velocityLayer: detected.velocityLayer ?? mapping.velocityLayer ?? 1,
    roundRobin: detected.roundRobin ?? mapping.roundRobin ?? 1,
    loopStart: mapping.loopStart,
    loopEnd: mapping.loopEnd,
  );
}

abstract class _DecentWavCandidate {
  const _DecentWavCandidate({
    required this.label,
    required this.groupLabel,
    this.mapping = const _DecentSampleMapping(),
  });

  final String label;
  final String groupLabel;
  final _DecentSampleMapping mapping;

  Future<File> materialize();

  PolySampleRegion toRegion(
    File file, {
    _AddWavMappingMode mappingMode = _AddWavMappingMode.preserve,
    int? spreadRootMidi,
    int? stackRootMidi,
    int? stackLowMidi,
    int? stackVelocityLayer,
    int? stackRoundRobin,
  }) {
    switch (mappingMode) {
      case _AddWavMappingMode.preserve:
        final source = _sourceMappedRegion(file);
        if (source.rootMidi != null) return source;
        return _detectedRegionFromFile(file, displayName: label);
      case _AddWavMappingMode.unmapped:
        return _customRegionFromFile(file, displayName: label);
      case _AddWavMappingMode.spread:
        final root = spreadRootMidi?.clamp(0, 127).toInt() ?? 36;
        return _mappedRegionFromFile(
          file,
          displayName: label,
          rootMidi: root,
          switchPoint: root,
          velocityLayer: 1,
          roundRobin: 1,
          loopStart: mapping.loopStart,
          loopEnd: mapping.loopEnd,
        );
      case _AddWavMappingMode.roundRobin:
        final root = (stackRootMidi ?? 36).clamp(0, 127).toInt();
        final low = (stackLowMidi ?? root).clamp(0, 127).toInt();
        final velocityLayer = (stackVelocityLayer ?? 1).clamp(1, 127).toInt();
        final roundRobin = (stackRoundRobin ?? 1).clamp(1, 999).toInt();
        return _mappedRegionFromFile(
          file,
          displayName: label,
          rootMidi: root,
          switchPoint: low,
          velocityLayer: velocityLayer,
          roundRobin: roundRobin,
          loopStart: mapping.loopStart,
          loopEnd: mapping.loopEnd,
        );
    }
  }

  PolySampleRegion _sourceMappedRegion(File file) {
    final base = _customRegionFromFile(file, displayName: label);
    final root = mapping.rootMidi;
    final region = base.copyWith(
      rootMidi: root,
      rootName: root == null
          ? null
          : PolyMultisampleParser.midiToNoteName(root),
      switchPoint: mapping.switchPoint,
      velocityLayer: mapping.velocityLayer,
      roundRobin: mapping.roundRobin,
      loopStart: mapping.loopStart,
      loopEnd: mapping.loopEnd,
    );
    return region.copyWithIssues(region.currentIssues);
  }
}

class _LocalDecentWavCandidate extends _DecentWavCandidate {
  const _LocalDecentWavCandidate({
    required this.file,
    required super.label,
    required super.groupLabel,
    super.mapping,
  });

  final File file;

  @override
  Future<File> materialize() async => file;
}

class _ArchiveDecentWavCandidate extends _DecentWavCandidate {
  const _ArchiveDecentWavCandidate({
    required this.sourceName,
    required this.entry,
    required super.label,
    required super.groupLabel,
    super.mapping,
  });

  final String sourceName;
  final ArchiveFile entry;

  @override
  Future<File> materialize() async {
    final dir = await Directory.systemTemp.createTemp('nt_helper_decent_pick_');
    final safeSource = sourceName.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_');
    final safeLabel = label.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_');
    final file = File(p.join(dir.path, '${safeSource}_$safeLabel'));
    await file.writeAsBytes(entry.content as List<int>);
    return file;
  }
}

class _DecentSampleMapping {
  const _DecentSampleMapping({
    this.path,
    this.rootMidi,
    this.switchPoint,
    this.velocityLow,
    this.velocityHigh,
    this.seqPosition,
    this.velocityLayer,
    this.roundRobin,
    this.loopStart,
    this.loopEnd,
  });

  final String? path;
  final int? rootMidi;
  final int? switchPoint;
  final int? velocityLow;
  final int? velocityHigh;
  final int? seqPosition;
  final int? velocityLayer;
  final int? roundRobin;
  final int? loopStart;
  final int? loopEnd;

  _DecentSampleMapping copyWith({int? velocityLayer, int? roundRobin}) {
    return _DecentSampleMapping(
      path: path,
      rootMidi: rootMidi,
      switchPoint: switchPoint,
      velocityLow: velocityLow,
      velocityHigh: velocityHigh,
      seqPosition: seqPosition,
      velocityLayer: velocityLayer ?? this.velocityLayer,
      roundRobin: roundRobin ?? this.roundRobin,
      loopStart: loopStart,
      loopEnd: loopEnd,
    );
  }
}

class _DecentWavGroup {
  const _DecentWavGroup({
    required this.label,
    required this.detail,
    required this.candidates,
  });

  final String label;
  final String detail;
  final List<_DecentWavCandidate> candidates;
}

class _DecentWavSelectionResult {
  const _DecentWavSelectionResult({
    required this.selected,
    required this.mappingMode,
    required this.spreadStartMidi,
    required this.stackRootMidi,
    required this.stackLowMidi,
    required this.stackVelocityLayer,
  });

  final Set<_DecentWavCandidate> selected;
  final _AddWavMappingMode mappingMode;
  final int spreadStartMidi;
  final int stackRootMidi;
  final int stackLowMidi;
  final int stackVelocityLayer;
}

class _DecentWavSelectionDialog extends StatefulWidget {
  const _DecentWavSelectionDialog({required this.groups});

  final List<_DecentWavGroup> groups;

  @override
  State<_DecentWavSelectionDialog> createState() =>
      _DecentWavSelectionDialogState();
}

class _DecentWavSelectionDialogState extends State<_DecentWavSelectionDialog> {
  final Set<_DecentWavCandidate> _selected = {};
  final AudioPlayer _previewPlayer = AudioPlayer();
  final Map<_DecentWavCandidate, File> _previewFiles = {};
  StreamSubscription<void>? _previewCompleteSubscription;
  _AddWavMappingMode _mappingMode = _AddWavMappingMode.preserve;
  int _spreadStartMidi = 36;
  int _stackRootMidi = 36;
  int _stackLowMidi = 36;
  int _stackVelocityLayer = 1;
  _DecentWavCandidate? _previewing;
  bool _previewBusy = false;

  @override
  void initState() {
    super.initState();
    _previewCompleteSubscription = _previewPlayer.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() => _previewing = null);
    });
  }

  @override
  void dispose() {
    _previewCompleteSubscription?.cancel();
    _previewPlayer.dispose();
    super.dispose();
  }

  int get _candidateCount =>
      widget.groups.fold(0, (total, group) => total + group.candidates.length);

  String _mappingModeLabel(_AddWavMappingMode mode) {
    switch (mode) {
      case _AddWavMappingMode.preserve:
        return 'Use source / filename mapping';
      case _AddWavMappingMode.unmapped:
        return 'Add unmapped';
      case _AddWavMappingMode.spread:
        return 'Spread across keys';
      case _AddWavMappingMode.roundRobin:
        return 'Stack as round robins';
    }
  }

  String _mappingModeHelp(_AddWavMappingMode mode) {
    switch (mode) {
      case _AddWavMappingMode.preserve:
        return 'Use Decent XML first; loose WAVs can still use C3, _V2, or _RR3 filename tags.';
      case _AddWavMappingMode.unmapped:
        return 'Add files with no root note so you can map them by hand.';
      case _AddWavMappingMode.spread:
        return 'Place selected WAVs one-per-key from the chosen start note.';
      case _AddWavMappingMode.roundRobin:
        return 'Put selected WAVs on one root/low note as RR1, RR2, RR3...';
    }
  }

  Future<void> _togglePreview(_DecentWavCandidate candidate) async {
    if (_previewing == candidate) {
      await _previewPlayer.stop();
      if (mounted) setState(() => _previewing = null);
      return;
    }

    setState(() => _previewBusy = true);
    try {
      await _previewPlayer.stop();
      final file = _previewFiles[candidate] ?? await candidate.materialize();
      _previewFiles[candidate] = file;
      await _previewPlayer.setReleaseMode(ReleaseMode.stop);
      await _previewPlayer.play(DeviceFileSource(file.path), volume: 1.0);
      if (mounted) setState(() => _previewing = candidate);
    } finally {
      if (mounted) setState(() => _previewBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Select WAVs to add'),
      content: SizedBox(
        width: 720,
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.groups.length} group(s), $_candidateCount WAV file(s). Choose whole groups, or expand for individual WAVs.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<_AddWavMappingMode>(
              value: _mappingMode,
              decoration: const InputDecoration(
                labelText: 'Mapping',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final mode in _AddWavMappingMode.values)
                  DropdownMenuItem(
                    value: mode,
                    child: Text(_mappingModeLabel(mode)),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _mappingMode = value);
              },
            ),
            if (_mappingMode == _AddWavMappingMode.spread) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: 180,
                child: _SampleNoteStepper(
                  label: 'Start',
                  value: _spreadStartMidi,
                  onChanged: (value) =>
                      setState(() => _spreadStartMidi = value),
                ),
              ),
            ],
            if (_mappingMode == _AddWavMappingMode.roundRobin) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: 170,
                    child: _SampleNoteStepper(
                      label: 'Root',
                      value: _stackRootMidi,
                      onChanged: (value) {
                        setState(() {
                          final lowWasRoot = _stackLowMidi == _stackRootMidi;
                          _stackRootMidi = value;
                          if (lowWasRoot) _stackLowMidi = value;
                        });
                      },
                    ),
                  ),
                  SizedBox(
                    width: 170,
                    child: _SampleNoteStepper(
                      label: 'Low',
                      value: _stackLowMidi,
                      onChanged: (value) =>
                          setState(() => _stackLowMidi = value),
                    ),
                  ),
                  SizedBox(
                    width: 170,
                    child: _SampleNumberStepper(
                      label: 'Velocity',
                      value: _stackVelocityLayer,
                      min: 1,
                      max: 127,
                      onChanged: (value) =>
                          setState(() => _stackVelocityLayer = value),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            Text(
              _mappingModeHelp(_mappingMode),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _selected
                      ..clear()
                      ..addAll(
                        widget.groups.expand((group) => group.candidates),
                      );
                  }),
                  child: const Text('Select all'),
                ),
                TextButton(
                  onPressed: () => setState(_selected.clear),
                  child: const Text('Clear'),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: widget.groups.length,
                itemBuilder: (context, index) {
                  final group = widget.groups[index];
                  final selectedCount = group.candidates
                      .where(_selected.contains)
                      .length;
                  final checked = selectedCount == 0
                      ? false
                      : selectedCount == group.candidates.length
                      ? true
                      : null;
                  return ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: Row(
                      children: [
                        Checkbox(
                          value: checked,
                          tristate: true,
                          onChanged: (value) => setState(() {
                            if (value ?? false) {
                              _selected.addAll(group.candidates);
                            } else {
                              _selected.removeAll(group.candidates);
                            }
                          }),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            group.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(left: 56),
                      child: Text(
                        group.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    children: [
                      for (final candidate in group.candidates)
                        CheckboxListTile(
                          dense: true,
                          value: _selected.contains(candidate),
                          secondary: IconButton(
                            tooltip: _previewing == candidate
                                ? 'Stop preview'
                                : 'Preview WAV',
                            onPressed: _previewBusy
                                ? null
                                : () => _togglePreview(candidate),
                            icon: Icon(
                              _previewing == candidate
                                  ? Icons.stop
                                  : Icons.play_arrow,
                            ),
                          ),
                          title: Text(
                            candidate.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onChanged: (value) => setState(() {
                            if (value ?? false) {
                              _selected.add(candidate);
                            } else {
                              _selected.remove(candidate);
                            }
                          }),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  _DecentWavSelectionResult(
                    selected: Set<_DecentWavCandidate>.of(_selected),
                    mappingMode: _mappingMode,
                    spreadStartMidi: _spreadStartMidi,
                    stackRootMidi: _stackRootMidi,
                    stackLowMidi: _stackLowMidi,
                    stackVelocityLayer: _stackVelocityLayer,
                  ),
                ),
          child: Text('Add ${_selected.length}'),
        ),
      ],
    );
  }
}

class _RenameChange {
  const _RenameChange({
    required this.source,
    required this.updated,
    required this.temporaryPath,
  });

  final PolySampleRegion source;
  final PolySampleRegion updated;
  final String temporaryPath;
}

class _AddChange {
  const _AddChange({
    required this.source,
    required this.updated,
    required this.targetPath,
  });

  final PolySampleRegion source;
  final PolySampleRegion updated;
  final String targetPath;
}

Map<String, String> _buildTargetNameMap(List<PolySampleRegion> regions) {
  final reservedNames = <String, int>{};
  return {
    for (final region in regions)
      region.path: _targetSampleFileName(region, regions, reservedNames),
  };
}

Map<String, _RenameChange> _buildRenamePlan(
  List<PolySampleRegion> baseline,
  List<PolySampleRegion> edited,
) {
  final baselineByPath = {for (final region in baseline) region.path: region};
  final targetNames = _buildTargetNameMap(edited);
  final changes = <String, _RenameChange>{};
  final stamp = DateTime.now().microsecondsSinceEpoch;

  for (var index = 0; index < edited.length; index++) {
    final region = edited[index];
    final source = baselineByPath[region.path];
    if (source == null) continue;
    final isNt = _isNtSdPath(source.path);
    final targetName = targetNames[region.path] ?? region.fileName;
    final targetPath = _replaceBasename(source.path, targetName, isNt: isNt);
    if (targetPath == source.path) continue;
    final temporaryPath = _replaceBasename(
      source.path,
      '.nthelper-$stamp-$index-${source.fileName}',
      isNt: isNt,
    );
    changes[source.path] = _RenameChange(
      source: source,
      updated: region.copyWith(
        path: targetPath,
        fileName: targetName,
        displayName: _replaceDisplayBasename(region.displayName, targetName),
      ),
      temporaryPath: temporaryPath,
    );
  }

  return changes;
}

Map<String, _AddChange> _buildAddPlan(
  List<PolySampleRegion> baseline,
  List<PolySampleRegion> edited,
  String outputFolder,
) {
  final baselinePaths = {for (final region in baseline) region.path};
  final targetNames = _buildTargetNameMap(edited);
  final isNtOutput = _isNtSdPath(outputFolder);
  final changes = <String, _AddChange>{};
  for (final region in edited) {
    if (baselinePaths.contains(region.path)) continue;
    final targetName = targetNames[region.path] ?? region.fileName;
    final targetPath = isNtOutput
        ? p.posix.join(outputFolder, targetName)
        : p.join(outputFolder, targetName);
    changes[region.path] = _AddChange(
      source: region,
      updated: region.copyWith(
        path: targetPath,
        fileName: targetName,
        displayName: _replaceDisplayBasename(region.displayName, targetName),
      ),
      targetPath: targetPath,
    );
  }
  return changes;
}

List<PolySampleRegion> _buildRemovePlan(
  List<PolySampleRegion> baseline,
  List<PolySampleRegion> edited,
) {
  final editedPaths = {for (final region in edited) region.path};
  return baseline
      .where((region) => !editedPaths.contains(region.path))
      .toList();
}

Future<void> _applyLocalDeletes(List<PolySampleRegion> removals) async {
  for (final region in removals) {
    final file = File(region.path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

Future<void> _applyLocalAdds(Map<String, _AddChange> additions) async {
  for (final change in additions.values) {
    final source = File(change.source.path);
    if (!await source.exists()) {
      throw Exception('Missing source WAV: ${change.source.path}');
    }
    if (change.source.path == change.targetPath) continue;
    final target = File(change.targetPath);
    if (await target.exists()) {
      throw Exception('Target already exists: ${change.targetPath}');
    }
    await target.parent.create(recursive: true);
    await source.copy(change.targetPath);
  }
}

Future<void> _applyLocalRenames(List<_RenameChange> changes) async {
  final sources = changes.map((change) => change.source.path).toSet();
  for (final change in changes) {
    if (!sources.contains(change.updated.path) &&
        await File(change.updated.path).exists()) {
      throw Exception('Target already exists: ${change.updated.path}');
    }
  }
  for (final change in changes) {
    await File(change.source.path).rename(change.temporaryPath);
  }
  for (final change in changes) {
    await File(change.temporaryPath).rename(change.updated.path);
  }
}

Future<void> _applyNtAdds(
  IDistingMidiManager manager,
  Map<String, _AddChange> additions,
) async {
  for (final change in additions.values) {
    final source = File(change.source.path);
    if (!await source.exists()) {
      throw Exception('Missing source WAV: ${change.source.path}');
    }
    final bytes = await source.readAsBytes();
    var offset = 0;
    const chunkSize = 512;
    while (offset < bytes.length) {
      final end = math.min(offset + chunkSize, bytes.length);
      final result = await manager.requestFileUploadChunk(
        change.targetPath,
        bytes.sublist(offset, end),
        offset,
        createAlways: offset == 0,
      );
      if (result != null && !result.success) {
        throw Exception(result.message);
      }
      offset = end;
    }
  }
}

Future<void> _applyNtDeletes(
  IDistingMidiManager manager,
  List<PolySampleRegion> removals,
) async {
  for (final region in removals) {
    final result = await manager.requestFileDelete(region.path);
    if (result != null && !result.success) {
      throw Exception(result.message);
    }
  }
}

Future<void> _applyNtRenames(
  IDistingMidiManager manager,
  List<_RenameChange> changes,
) async {
  for (final change in changes) {
    final result = await manager.requestFileRename(
      change.source.path,
      change.temporaryPath,
    );
    if (result != null && !result.success) {
      throw Exception(result.message);
    }
  }
  for (final change in changes) {
    final result = await manager.requestFileRename(
      change.temporaryPath,
      change.updated.path,
    );
    if (result != null && !result.success) {
      throw Exception(result.message);
    }
  }
}

String _targetSampleFileName(
  PolySampleRegion region,
  List<PolySampleRegion> regions,
  Map<String, int> reservedNames,
) {
  final extension = p.extension(region.fileName);
  final prefix = _sampleNamePrefix(region.fileName);
  final rootName =
      region.rootName ??
      (region.rootMidi == null
          ? null
          : PolyMultisampleParser.midiToNoteName(region.rootMidi!));
  if (rootName == null) return region.fileName;

  final parts = <String>[if (prefix.isNotEmpty) prefix, rootName];
  final low = _effectiveLow(region);
  if (low != null && low != region.rootMidi) {
    parts.add('SW$low');
  }
  if (_shouldWriteVelocity(region, regions)) {
    parts.add('V${region.velocityLayer ?? 1}');
  }
  if (_shouldWriteRoundRobin(region, regions)) {
    parts.add('RR${region.roundRobin ?? 1}');
  }

  final stem = parts.join('_');
  final count = (reservedNames[stem] ?? 0) + 1;
  reservedNames[stem] = count;
  return count == 1 ? '$stem$extension' : '${stem}__dup$count$extension';
}

String _sampleNamePrefix(String fileName) {
  final stem = p.basenameWithoutExtension(fileName);
  final parts = stem.split('_');
  var noteIndex = -1;
  for (var i = 0; i < parts.length; i++) {
    if (_isNoteTag(parts[i])) noteIndex = i;
  }
  if (noteIndex <= 0) return noteIndex == 0 ? '' : stem;
  return parts.take(noteIndex).join('_');
}

bool _isNoteTag(String value) {
  return RegExp(r'^[A-Ga-g](?:#|b)?-?\d+$').hasMatch(value);
}

bool _hasVelocityTag(String fileName) {
  return RegExp(
    r'(?:^|_)V\d+(?=$|_)',
  ).hasMatch(p.basenameWithoutExtension(fileName).toUpperCase());
}

bool _hasRoundRobinTag(String fileName) {
  return RegExp(
    r'(?:^|_)RR\d+(?=$|_)',
  ).hasMatch(p.basenameWithoutExtension(fileName).toUpperCase());
}

bool _shouldWriteVelocity(
  PolySampleRegion region,
  List<PolySampleRegion> regions,
) {
  return _hasVelocityTag(region.fileName) ||
      _sortedSampleLanes(regions).length > 1;
}

bool _shouldWriteRoundRobin(
  PolySampleRegion region,
  List<PolySampleRegion> regions,
) {
  if (_hasRoundRobinTag(region.fileName)) return true;
  final low = _effectiveLow(region);
  if (low == null) return false;
  final siblings = regions.where((candidate) {
    return candidate.path != region.path &&
        (candidate.velocityLayer ?? 1) == (region.velocityLayer ?? 1) &&
        candidate.rootMidi == region.rootMidi &&
        _effectiveLow(candidate) == low;
  });
  return siblings.isNotEmpty || (region.roundRobin ?? 1) != 1;
}

String _replaceBasename(String path, String fileName, {required bool isNt}) {
  if (isNt) {
    final dir = p.posix.dirname(path);
    return dir == '.' ? fileName : p.posix.join(dir, fileName);
  }
  return p.join(p.dirname(path), fileName);
}

String _replaceDisplayBasename(String displayName, String fileName) {
  final normalized = displayName.replaceAll('\\', '/');
  final dir = p.posix.dirname(normalized);
  return dir == '.' ? fileName : p.posix.join(dir, fileName);
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
    this.warning = false,
  });

  final String label;
  final String value;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = warning
        ? colorScheme.onTertiaryContainer
        : colorScheme.onSecondaryContainer;
    final background = warning
        ? colorScheme.tertiaryContainer
        : colorScheme.secondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _DraftStatusChip extends StatelessWidget {
  const _DraftStatusChip({required this.dirty});

  final bool dirty;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dirty
            ? colorScheme.tertiaryContainer.withValues(alpha: 0.55)
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.24),
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        dirty ? 'Unsaved draft' : 'Draft only',
        style: TextStyle(
          color: dirty
              ? colorScheme.onTertiaryContainer
              : colorScheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _PreviewGainControl extends StatelessWidget {
  const _PreviewGainControl({required this.valueDb, required this.onChanged});

  final double valueDb;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return SizedBox(
      width: 190,
      child: Row(
        children: [
          Icon(Icons.volume_down, size: 18, color: colorScheme.primary),
          const SizedBox(width: 4),
          Expanded(
            child: Slider(
              value: valueDb,
              min: -36,
              max: 6,
              divisions: 42,
              label: '${valueDb.round()} dB',
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
              '${valueDb.round()} dB',
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyMapSection extends StatefulWidget {
  const _KeyMapSection({
    required this.instrument,
    required this.selected,
    required this.lanes,
    required this.minMidi,
    required this.maxMidi,
    required this.mapRevision,
    required this.onSelectRegion,
  });

  final PolySampleInstrument instrument;
  final PolySampleRegion? selected;
  final List<_SampleLane> lanes;
  final int minMidi;
  final int maxMidi;
  final int mapRevision;
  final ValueChanged<PolySampleRegion> onSelectRegion;

  @override
  State<_KeyMapSection> createState() => _KeyMapSectionState();
}

class _KeyMapSectionState extends State<_KeyMapSection> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollHorizontally(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scrollController.hasClients) {
      return;
    }
    final delta = event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    final next = (_scrollController.offset + delta).clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.jumpTo(next);
  }

  void _dragScrollHorizontally(DragUpdateDetails details) {
    if (!_scrollController.hasClients) return;
    final next = (_scrollController.offset - details.delta.dx).clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.jumpTo(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final range = _rangeLabel(widget.instrument.regions);
    return SizedBox(
      height: 300,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
              child: Row(
                children: [
                  Text('Key Map', style: theme.textTheme.titleSmall),
                  const SizedBox(width: 12),
                  Text(
                    'read-only overview',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    range,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colorScheme.outlineVariant),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final keyCount = widget.maxMidi - widget.minMidi;
                  final canvasWidth = math.max(
                    constraints.maxWidth,
                    keyCount * 24.0 + 80,
                  );
                  return Listener(
                    onPointerSignal: _scrollHorizontally,
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: canvasWidth,
                        height: constraints.maxHeight,
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: _KeyboardMapPainter(
                              regions: widget.instrument.regions,
                              selected: widget.selected,
                              lanes: widget.lanes,
                              minMidi: widget.minMidi,
                              maxMidi: widget.maxMidi,
                              mapRevision: widget.mapRevision,
                              colorScheme: colorScheme,
                            ),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onHorizontalDragUpdate: _dragScrollHorizontally,
                              onTapUp: (details) {
                                final region = _regionAtPosition(
                                  details.localPosition,
                                  Size(canvasWidth, constraints.maxHeight),
                                );
                                if (region != null) {
                                  widget.onSelectRegion(region);
                                }
                              },
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _rangeLabel(List<PolySampleRegion> regions) {
    final extents = _midiExtentsForRegions(regions);
    if (extents.isEmpty) return 'No mapped notes';
    extents.sort();
    return '${PolyMultisampleParser.midiToNoteName(extents.first)} - '
        '${PolyMultisampleParser.midiToNoteName(extents.last)}';
  }

  PolySampleRegion? _regionAtPosition(Offset position, Size size) {
    final layout = _MapLayout.fromRegions(
      widget.instrument.regions,
      widget.lanes,
      size,
      minMidi: widget.minMidi,
      maxMidi: widget.maxMidi,
    );
    if (position.dx < layout.left ||
        position.dx > layout.right ||
        position.dy < layout.zoneTop ||
        position.dy > layout.zoneBottom) {
      return null;
    }

    final zones = _mapZonesFor(widget.instrument.regions);
    for (final zone in zones.reversed) {
      final layerIndex = layout.sortedLanes.indexOf(zone.lane);
      final lane = layerIndex < 0 ? 0 : layerIndex;
      final range = zone.range;
      final x0 =
          layout.left +
          ((range.start - layout.minMidi) / layout.midiSpan) * layout.width;
      final x1 =
          layout.left +
          ((range.end + 1 - layout.minMidi) / layout.midiSpan) * layout.width;
      final y0 = layout.zoneTop + lane * layout.laneHeight;
      final y1 = y0 + layout.laneHeight;
      final rect = Rect.fromLTRB(x0, y0, x1, y1);
      if (rect.contains(position)) {
        return zone.pick(widget.selected);
      }
    }
    return null;
  }
}

class _MapLayout {
  _MapLayout({
    required this.minMidi,
    required this.maxMidi,
    required this.left,
    required this.right,
    required this.width,
    required this.zoneTop,
    required this.zoneBottom,
    required this.laneHeight,
    required this.sortedLanes,
    required this.keyboardTop,
    required this.keyboardBottom,
  });

  final int minMidi;
  final int maxMidi;
  final double left;
  final double right;
  final double width;
  final double zoneTop;
  final double zoneBottom;
  final double laneHeight;
  final List<_SampleLane> sortedLanes;
  final double keyboardTop;
  final double keyboardBottom;

  int get midiSpan => maxMidi - minMidi;

  static _MapLayout fromRegions(
    List<PolySampleRegion> regions,
    List<_SampleLane> lanes,
    Size size, {
    required int minMidi,
    required int maxMidi,
  }) {
    final sortedLanes = _displaySampleLanes(regions, lanes);

    final left = sortedLanes.length > 1 ? 58.0 : 18.0;
    final right = size.width - 18.0;
    final width = math.max(1.0, right - left);
    const labelHeight = 26.0;
    const keyboardHeight = 36.0;
    const bottomPadding = 8.0;
    final zoneTop = labelHeight;
    final zoneBottom = size.height - keyboardHeight - bottomPadding;
    final zoneHeight = math.max(22.0, zoneBottom - zoneTop);
    final laneHeight = zoneHeight / sortedLanes.length;
    return _MapLayout(
      minMidi: minMidi,
      maxMidi: maxMidi,
      left: left,
      right: right,
      width: width,
      zoneTop: zoneTop,
      zoneBottom: zoneBottom,
      laneHeight: laneHeight,
      sortedLanes: sortedLanes,
      keyboardTop: zoneBottom,
      keyboardBottom: size.height - bottomPadding,
    );
  }
}

class _SampleLane implements Comparable<_SampleLane> {
  const _SampleLane(this.velocity);

  final int velocity;

  String get label => 'V$velocity';

  @override
  int compareTo(_SampleLane other) {
    return velocity.compareTo(other.velocity);
  }

  @override
  bool operator ==(Object other) {
    return other is _SampleLane && velocity == other.velocity;
  }

  @override
  int get hashCode => velocity.hashCode;
}

_SampleLane _laneFor(PolySampleRegion region) {
  return _SampleLane(region.velocityLayer ?? 1);
}

List<_SampleLane> _sortedSampleLanes(List<PolySampleRegion> regions) {
  final lanes =
      regions
          .where((region) => region.rootMidi != null)
          .map(_laneFor)
          .toSet()
          .toList()
        ..sort();
  if (lanes.isEmpty) {
    lanes.add(const _SampleLane(1));
  }
  return lanes;
}

List<_SampleLane> _displaySampleLanes(
  List<PolySampleRegion> regions,
  List<_SampleLane> lanes,
) {
  final sorted = lanes.isEmpty
      ? _sortedSampleLanes(regions)
      : (List<_SampleLane>.of(lanes)..sort());
  return sorted.reversed.toList();
}

class _RangeBounds {
  const _RangeBounds({required this.start, required this.end});

  final int start;
  final int end;

  String get label =>
      '${PolyMultisampleParser.midiToNoteName(start)} - '
      '${PolyMultisampleParser.midiToNoteName(end)}';
}

class _MapZone {
  const _MapZone({
    required this.lane,
    required this.range,
    required this.rootMidi,
    required this.regions,
  });

  final _SampleLane lane;
  final _RangeBounds range;
  final int rootMidi;
  final List<PolySampleRegion> regions;

  bool contains(PolySampleRegion? region) {
    if (region == null) return false;
    return regions.any((candidate) => candidate.path == region.path);
  }

  PolySampleRegion pick(PolySampleRegion? selected) {
    if (contains(selected)) return selected!;
    return regions.first;
  }

  String get label {
    final first = regions.first;
    final root =
        first.rootName ?? PolyMultisampleParser.midiToNoteName(rootMidi);
    final velocity = 'V${first.velocityLayer ?? 1}';
    final rrs = regions.map((region) => region.roundRobin ?? 1).toSet().toList()
      ..sort();
    if (rrs.length <= 1) return '$root $velocity';
    return '$root $velocity RR${rrs.first}-${rrs.last}';
  }

  String get compactLabel {
    final first = regions.first;
    final root =
        first.rootName ?? PolyMultisampleParser.midiToNoteName(rootMidi);
    final rrs = regions.map((region) => region.roundRobin ?? 1).toSet().toList()
      ..sort();
    if (rrs.length <= 1) return root;
    return 'R${rrs.first}-${rrs.last}';
  }
}

List<_MapZone> _mapZonesFor(List<PolySampleRegion> regions) {
  final groups = <String, List<PolySampleRegion>>{};
  for (final region in regions.where((region) => region.rootMidi != null)) {
    final low = _effectiveLow(region);
    if (low == null) continue;
    final key = '${region.velocityLayer ?? 1}|$low|${region.rootMidi}';
    groups.putIfAbsent(key, () => <PolySampleRegion>[]).add(region);
  }

  final zones = <_MapZone>[];
  for (final group in groups.values) {
    group.sort((a, b) {
      final rrCompare = (a.roundRobin ?? 1).compareTo(b.roundRobin ?? 1);
      if (rrCompare != 0) return rrCompare;
      return a.displayName.compareTo(b.displayName);
    });
    final first = group.first;
    final range = _rangeBoundsForRegion(first, regions);
    if (range == null) continue;
    zones.add(
      _MapZone(
        lane: _laneFor(first),
        range: range,
        rootMidi: first.rootMidi!,
        regions: group,
      ),
    );
  }
  zones.sort((a, b) {
    final laneCompare = a.lane.compareTo(b.lane);
    if (laneCompare != 0) return laneCompare;
    final lowCompare = a.range.start.compareTo(b.range.start);
    if (lowCompare != 0) return lowCompare;
    return a.rootMidi.compareTo(b.rootMidi);
  });
  return zones;
}

List<PolySampleRegion> _withExplicitSwitchPoints(
  List<PolySampleRegion> regions,
) {
  final output = List<PolySampleRegion>.of(regions);
  for (var i = 0; i < output.length; i++) {
    final region = output[i];
    final root = region.rootMidi;
    if (root == null) continue;
    output[i] = region.copyWith(switchPoint: (region.switchPoint ?? root));
  }
  return output;
}

int? _effectiveLow(PolySampleRegion region) {
  final root = region.rootMidi;
  if (root == null) return null;
  return (region.switchPoint ?? root).clamp(0, 127).toInt();
}

bool _sameBoundaryGroup(PolySampleRegion a, PolySampleRegion b) {
  return a.rootMidi != null &&
      b.rootMidi != null &&
      a.rootMidi == b.rootMidi &&
      _effectiveLow(a) == _effectiveLow(b);
}

List<PolySampleRegion> _keyBoundaryRegions(List<PolySampleRegion> regions) {
  final boundaries = regions
      .where((candidate) => candidate.rootMidi != null)
      .toList();
  boundaries.sort((a, b) {
    final lowCompare = _effectiveLow(a)!.compareTo(_effectiveLow(b)!);
    if (lowCompare != 0) return lowCompare;
    final rootCompare = (a.rootMidi ?? 999).compareTo(b.rootMidi ?? 999);
    if (rootCompare != 0) return rootCompare;
    return a.path.compareTo(b.path);
  });
  return boundaries;
}

List<PolySampleRegion> _keyBoundaryRegionsInLane(
  PolySampleRegion region,
  List<PolySampleRegion> regions,
) {
  final velocity = region.velocityLayer ?? 1;
  return _keyBoundaryRegions(
    regions
        .where((candidate) => (candidate.velocityLayer ?? 1) == velocity)
        .toList(),
  );
}

PolySampleRegion? _previousRegionInLane(
  PolySampleRegion region,
  List<PolySampleRegion> regions,
) {
  final boundaries = _keyBoundaryRegionsInLane(region, regions);
  final low = _effectiveLow(region);
  if (low == null) return null;
  PolySampleRegion? previous;
  for (final candidate in boundaries) {
    final candidateLow = _effectiveLow(candidate)!;
    if (candidateLow >= low) break;
    previous = candidate;
  }
  return previous;
}

PolySampleRegion? _nextRegionInLane(
  PolySampleRegion region,
  List<PolySampleRegion> regions,
) {
  final boundaries = _keyBoundaryRegionsInLane(region, regions);
  final low = _effectiveLow(region);
  if (low == null) return null;
  for (final candidate in boundaries) {
    if (_effectiveLow(candidate)! > low) return candidate;
  }
  return null;
}

List<PolySampleRegion> _boundarySiblings(
  PolySampleRegion region,
  List<PolySampleRegion> regions,
) {
  final low = _effectiveLow(region);
  if (low == null) return [region];
  return regions.where((candidate) {
    return _sameBoundaryGroup(region, candidate);
  }).toList();
}

List<PolySampleRegion> _roundRobinSiblings(
  PolySampleRegion region,
  List<PolySampleRegion> regions,
) {
  return _boundarySiblings(region, regions).where((candidate) {
    return (candidate.velocityLayer ?? 1) == (region.velocityLayer ?? 1);
  }).toList();
}

PolySampleRegion? _regionInSnapshot(
  PolySampleRegion region,
  List<PolySampleRegion> regions,
) {
  for (final candidate in regions) {
    if (candidate.path == region.path) return candidate;
  }
  return null;
}

int _lowMinFor(PolySampleRegion region, List<PolySampleRegion> regions) {
  final previous = _previousRegionInLane(region, regions);
  if (previous == null) return 0;
  return math.min(127, _effectiveLow(previous)! + 1);
}

int _lowMaxFor(PolySampleRegion region, List<PolySampleRegion> regions) {
  final min = _lowMinFor(region, regions);
  final next = _nextRegionInLane(region, regions);
  if (next == null) return 127;
  return math.max(min, _effectiveLow(next)! - 1);
}

int _highFor(PolySampleRegion region, List<PolySampleRegion> regions) {
  final next = _nextRegionInLane(region, regions);
  if (next == null) return 127;
  return math.max(_effectiveLow(region)!, _effectiveLow(next)! - 1);
}

int _highMaxFor(PolySampleRegion region, List<PolySampleRegion> regions) {
  final min = _highMinFor(region);
  final next = _nextRegionInLane(region, regions);
  if (next == null) return 127;
  final afterNext = _nextRegionInLane(next, regions);
  if (afterNext == null) return math.max(min, 126);
  return math.max(min, _effectiveLow(afterNext)! - 2);
}

int _highMinFor(PolySampleRegion region) {
  return _effectiveLow(region) ?? 0;
}

List<int> _midiExtentsForRegions(List<PolySampleRegion> regions) {
  final extents = <int>[];
  for (final region in regions) {
    if (_effectiveLow(region) case final low?) {
      extents.add(low);
      extents.add(_highFor(region, regions));
    }
  }
  return extents;
}

int _initialMapMinMidi(List<PolySampleRegion> regions) {
  return 0;
}

int _initialMapMaxMidi(List<PolySampleRegion> regions, int minMidi) {
  final extents = _midiExtentsForRegions(regions);
  if (extents.isEmpty) return 128;
  extents.sort();
  return (((extents.last / 12).ceil() * 12) + 12)
      .clamp(minMidi + 12, 128)
      .toInt();
}

PolySampleRegion _updateRoot(PolySampleRegion region, int midi) {
  final root = midi.clamp(0, 127).toInt();
  return region.copyWith(
    rootMidi: root,
    rootName: PolyMultisampleParser.midiToNoteName(root),
  );
}

_RangeBounds? _rangeBoundsForRegion(
  PolySampleRegion region,
  List<PolySampleRegion> regions,
) {
  final index = regions.indexWhere(
    (candidate) => candidate.path == region.path,
  );
  return _rangeBoundsForRegionAtIndex(index, regions);
}

_RangeBounds? _rangeBoundsForRegionAtIndex(
  int index,
  List<PolySampleRegion> regions,
) {
  if (index < 0 || index >= regions.length) return null;
  final region = regions[index];
  if (region.rootMidi == null) return null;
  final start = _effectiveLow(region)!;
  final end = _highFor(region, regions);

  return _RangeBounds(start: start, end: end);
}

class _SampleList extends StatefulWidget {
  const _SampleList({
    required this.regions,
    required this.selected,
    required this.selectedPaths,
    required this.onSelectRegion,
    required this.onSelectRegionFromList,
    required this.onChangeRegion,
    required this.onChangeRoot,
    required this.onChangeVelocity,
    required this.onChangeLow,
    required this.onChangeHigh,
  });

  final List<PolySampleRegion> regions;
  final PolySampleRegion? selected;
  final Set<String> selectedPaths;
  final ValueChanged<PolySampleRegion> onSelectRegion;
  final void Function(
    PolySampleRegion region, {
    required bool toggle,
    required bool extend,
  })
  onSelectRegionFromList;
  final ValueChanged<PolySampleRegion> onChangeRegion;
  final void Function(PolySampleRegion region, int value) onChangeRoot;
  final void Function(PolySampleRegion region, int value) onChangeVelocity;
  final void Function(PolySampleRegion region, int value) onChangeLow;
  final void Function(PolySampleRegion region, int value) onChangeHigh;

  @override
  State<_SampleList> createState() => _SampleListState();
}

const double _sampleListRowHeight = 52;
const double _sampleListSeparatorHeight = 1;

class _SampleListState extends State<_SampleList> {
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'PolySampleList');
  String? _lastSelectedPath;

  @override
  void didUpdateWidget(covariant _SampleList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selectedPath = widget.selected?.path;
    if (selectedPath != null && selectedPath != _lastSelectedPath) {
      _lastSelectedPath = selectedPath;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final index = widget.regions.indexWhere(
          (region) => region.path == selectedPath,
        );
        if (index < 0) return;
        final rowTop =
            index * (_sampleListRowHeight + _sampleListSeparatorHeight);
        final centered =
            rowTop -
            ((_scrollController.position.viewportDimension -
                    _sampleListRowHeight) /
                2);
        final target = centered.clamp(
          _scrollController.position.minScrollExtent,
          _scrollController.position.maxScrollExtent,
        );
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      return _selectRelative(1);
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      return _selectRelative(-1);
    }
    if (event.logicalKey == LogicalKeyboardKey.home) {
      return _selectIndex(0);
    }
    if (event.logicalKey == LogicalKeyboardKey.end) {
      return _selectIndex(widget.regions.length - 1);
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _selectRelative(int delta) {
    if (widget.regions.isEmpty) return KeyEventResult.ignored;
    final selectedPath = widget.selected?.path;
    final currentIndex = selectedPath == null
        ? -1
        : widget.regions.indexWhere((region) => region.path == selectedPath);
    final fallbackIndex = delta > 0 ? 0 : widget.regions.length - 1;
    final nextIndex = currentIndex < 0
        ? fallbackIndex
        : (currentIndex + delta).clamp(0, widget.regions.length - 1).toInt();
    return _selectIndex(nextIndex);
  }

  KeyEventResult _selectIndex(int index) {
    if (index < 0 || index >= widget.regions.length) {
      return KeyEventResult.ignored;
    }
    final region = widget.regions[index];
    if (region.path == widget.selected?.path) {
      return KeyEventResult.handled;
    }
    _focusNode.requestFocus();
    widget.onSelectRegion(region);
    return KeyEventResult.handled;
  }

  void _handleRowTap(PolySampleRegion region) {
    _focusNode.requestFocus();
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final toggle =
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight);
    final extend =
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    widget.onSelectRegionFromList(region, toggle: toggle, extend: extend);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _focusNode.requestFocus,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                child: Row(
                  children: [
                    Text('Samples', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    Text(
                      '${widget.regions.length} files',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colorScheme.outlineVariant),
              Expanded(
                child: ListView.separated(
                  controller: _scrollController,
                  itemCount: widget.regions.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: colorScheme.outlineVariant),
                  itemBuilder: (context, index) {
                    final region = widget.regions[index];
                    return SizedBox(
                      height: _sampleListRowHeight,
                      child: _SampleListRow(
                        region: region,
                        regions: widget.regions,
                        selected: widget.selectedPaths.contains(region.path),
                        primarySelected: region.path == widget.selected?.path,
                        onTap: () => _handleRowTap(region),
                        onChangeRegion: widget.onChangeRegion,
                        onChangeRoot: widget.onChangeRoot,
                        onChangeVelocity: widget.onChangeVelocity,
                        onChangeLow: widget.onChangeLow,
                        onChangeHigh: widget.onChangeHigh,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SampleListRow extends StatelessWidget {
  const _SampleListRow({
    required this.region,
    required this.regions,
    required this.selected,
    required this.primarySelected,
    required this.onTap,
    required this.onChangeRegion,
    required this.onChangeRoot,
    required this.onChangeVelocity,
    required this.onChangeLow,
    required this.onChangeHigh,
  });

  final PolySampleRegion region;
  final List<PolySampleRegion> regions;
  final bool selected;
  final bool primarySelected;
  final VoidCallback onTap;
  final ValueChanged<PolySampleRegion> onChangeRegion;
  final void Function(PolySampleRegion region, int value) onChangeRoot;
  final void Function(PolySampleRegion region, int value) onChangeVelocity;
  final void Function(PolySampleRegion region, int value) onChangeLow;
  final void Function(PolySampleRegion region, int value) onChangeHigh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final range = _rangeBoundsForRegion(region, regions);
    return Material(
      color: selected
          ? colorScheme.primary.withValues(alpha: 0.16)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.audio_file,
                size: 20,
                color: primarySelected
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  region.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: primarySelected
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _SampleNoteStepper(
                label: 'Root',
                value: region.rootMidi,
                onChanged: (value) => onChangeRoot(region, value),
              ),
              const SizedBox(width: 6),
              if (range != null) ...[
                _SampleNoteStepper(
                  label: 'Low',
                  value: range.start,
                  min: _lowMinFor(region, regions),
                  max: _lowMaxFor(region, regions),
                  onChanged: (value) => onChangeLow(region, value),
                ),
                const SizedBox(width: 6),
                _SampleNoteStepper(
                  label: 'High',
                  value: range.end,
                  min: _highMinFor(region),
                  max: _highMaxFor(region, regions),
                  onChanged: _nextRegionInLane(region, regions) == null
                      ? null
                      : (value) => onChangeHigh(region, value),
                ),
                const SizedBox(width: 6),
              ],
              _SampleNumberStepper(
                label: 'Vel',
                value: region.velocityLayer ?? 1,
                min: 1,
                max: 16,
                onChanged: (value) => onChangeVelocity(region, value),
              ),
              const SizedBox(width: 6),
              _SampleNumberStepper(
                label: 'RR',
                value: region.roundRobin ?? 1,
                min: 1,
                max: 32,
                onChanged: (value) =>
                    onChangeRegion(region.copyWith(roundRobin: value)),
              ),
              const SizedBox(width: 10),
              _IssueLabel(region: region),
            ],
          ),
        ),
      ),
    );
  }
}

class _SampleNoteStepper extends StatelessWidget {
  const _SampleNoteStepper({
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 127,
  });

  final String label;
  final int? value;
  final ValueChanged<int>? onChanged;
  final int min;
  final int max;

  @override
  Widget build(BuildContext context) {
    final current = value ?? 60;
    return _SampleEditStepper(
      label: label,
      value: value == null
          ? '-'
          : PolyMultisampleParser.midiToNoteName(current),
      onDecrement: onChanged == null || current <= min
          ? null
          : () => onChanged!(current - 1),
      onIncrement: onChanged == null || current >= max
          ? null
          : () => onChanged!(current + 1),
    );
  }
}

class _SampleNumberStepper extends StatelessWidget {
  const _SampleNumberStepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return _SampleEditStepper(
      label: label,
      value: value.toString(),
      onDecrement: value <= min ? null : () => onChanged(value - 1),
      onIncrement: value >= max ? null : () => onChanged(value + 1),
    );
  }
}

class _SampleEditStepper extends StatelessWidget {
  const _SampleEditStepper({
    required this.label,
    required this.value,
    required this.onDecrement,
    required this.onIncrement,
  });

  final String label;
  final String value;
  final VoidCallback? onDecrement;
  final VoidCallback? onIncrement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 32,
      constraints: const BoxConstraints(minWidth: 104),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.22),
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Decrease $label',
            onPressed: onDecrement,
            icon: const Icon(Icons.remove),
            iconSize: 14,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 32),
          ),
          Expanded(
            child: Text(
              '$label $value',
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Increase $label',
            onPressed: onIncrement,
            icon: const Icon(Icons.add),
            iconSize: 14,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 32),
          ),
        ],
      ),
    );
  }
}

class _IssueLabel extends StatelessWidget {
  const _IssueLabel({required this.region});

  final PolySampleRegion region;

  @override
  Widget build(BuildContext context) {
    final issues = region.currentIssues;
    if (issues.isEmpty) {
      return const Text('OK');
    }
    final colorScheme = Theme.of(context).colorScheme;
    return Text(
      issues.map(_issueText).join(', '),
      style: TextStyle(color: colorScheme.tertiary),
    );
  }

  String _issueText(PolySampleIssue issue) {
    return switch (issue) {
      PolySampleIssue.missingRootNote => 'No root',
      PolySampleIssue.unsupportedFileType => 'Unsupported',
    };
  }
}

class _SampleInspector extends StatelessWidget {
  const _SampleInspector({
    required this.region,
    required this.regions,
    required this.waveform,
    required this.cachedWaveform,
    required this.canPreviewAudio,
    required this.isPreviewPlaying,
    required this.loopPreviewEnabled,
    required this.waveformMessage,
    required this.loopDraft,
    required this.loopEnabled,
    required this.loopDirty,
    required this.savingLoop,
    required this.wavEditDraft,
    required this.waveformMode,
    required this.renderingWav,
    required this.onChangeLoop,
    required this.onChangeLoopEnabled,
    required this.onChangeWavEdit,
    required this.onChangeWaveformMode,
    required this.onSelectRegion,
    required this.onChooseFolder,
    required this.onRevealFolder,
    required this.onSaveLoop,
    required this.onSaveWav,
    required this.onSaveWavAs,
    required this.onTogglePreview,
    required this.onToggleLoopPreview,
  });

  final PolySampleRegion? region;
  final List<PolySampleRegion> regions;
  final Future<WavOverview?>? waveform;
  final WavOverview? cachedWaveform;
  final bool canPreviewAudio;
  final bool isPreviewPlaying;
  final bool loopPreviewEnabled;
  final String? waveformMessage;
  final _LoopMarkerDraft? loopDraft;
  final bool loopEnabled;
  final bool loopDirty;
  final bool savingLoop;
  final _WavEditDraft? wavEditDraft;
  final _WaveformMode waveformMode;
  final bool renderingWav;
  final void Function(PolySampleRegion region, _LoopMarkerDraft markers)
  onChangeLoop;
  final void Function(PolySampleRegion region, bool enabled)
  onChangeLoopEnabled;
  final void Function(PolySampleRegion region, _WavEditDraft draft)
  onChangeWavEdit;
  final ValueChanged<_WaveformMode> onChangeWaveformMode;
  final ValueChanged<PolySampleRegion> onSelectRegion;
  final Future<void> Function() onChooseFolder;
  final VoidCallback? onRevealFolder;
  final Future<void> Function()? onSaveLoop;
  final Future<void> Function()? onSaveWav;
  final Future<void> Function()? onSaveWavAs;
  final Future<void> Function(PolySampleRegion region) onTogglePreview;
  final Future<void> Function(bool enabled) onToggleLoopPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final r = region;
    if (r == null) {
      return const Center(child: Text('No sample selected'));
    }
    final sampleIndex = regions.indexWhere((region) => region.path == r.path);
    final previous = sampleIndex > 0 ? regions[sampleIndex - 1] : null;
    final next = sampleIndex >= 0 && sampleIndex < regions.length - 1
        ? regions[sampleIndex + 1]
        : null;

    return SingleChildScrollView(
      key: PageStorageKey('poly-sample-inspector-${r.path}'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Sample', style: theme.textTheme.titleMedium),
              ),
              IconButton(
                tooltip: 'Previous sample',
                onPressed: previous == null
                    ? null
                    : () => onSelectRegion(previous),
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: 'Next sample',
                onPressed: next == null ? null : () => onSelectRegion(next),
                icon: const Icon(Icons.chevron_right),
              ),
              IconButton(
                tooltip: 'Reveal selected sample in Explorer',
                onPressed: onRevealFolder,
                icon: const Icon(Icons.open_in_new),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            r.fileName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onChooseFolder,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Load folder'),
          ),
          const SizedBox(height: 18),
          _WaveformSection(
            waveform: waveform,
            cachedWaveform: cachedWaveform,
            mode: waveformMode,
            canPreviewAudio: canPreviewAudio,
            isPreviewPlaying: isPreviewPlaying,
            loopPreviewEnabled: loopPreviewEnabled,
            unavailableMessage: waveformMessage,
            loopDraft: loopDraft,
            loopEnabled: loopEnabled,
            loopDirty: loopDirty,
            savingLoop: savingLoop,
            wavEditDraft: wavEditDraft,
            renderingWav: renderingWav,
            onChangeMode: onChangeWaveformMode,
            onChanged: (markers) => onChangeLoop(r, markers),
            onChangeLoopEnabled: (enabled) => onChangeLoopEnabled(r, enabled),
            onChangeWavEdit: (draft) => onChangeWavEdit(r, draft),
            onSaveLoop: onSaveLoop,
            onSaveWav: onSaveWav,
            onSaveWavAs: onSaveWavAs,
            onTogglePreview: () => onTogglePreview(r),
            onToggleLoopPreview: onToggleLoopPreview,
          ),
          const SizedBox(height: 24),
          Text(
            r.path,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoopMarkerDraft {
  const _LoopMarkerDraft({
    required this.loopStartFrame,
    required this.loopEndFrame,
  });

  final int loopStartFrame;
  final int loopEndFrame;

  factory _LoopMarkerDraft.fromWaveform(WavOverview waveform) {
    return _LoopMarkerDraft(
      loopStartFrame: waveform.loopStart ?? 0,
      loopEndFrame: waveform.loopEnd ?? math.max(0, waveform.frameCount - 1),
    ).clamped(waveform.frameCount);
  }

  _LoopMarkerDraft clamped(int frameCount) {
    final maxFrame = math.max(0, frameCount - 1);
    final loopStart = loopStartFrame.clamp(0, maxFrame).toInt();
    final loopEnd = loopEndFrame.clamp(loopStart, maxFrame).toInt();
    return _LoopMarkerDraft(loopStartFrame: loopStart, loopEndFrame: loopEnd);
  }

  _LoopMarkerDraft copyWith({
    int? loopStartFrame,
    int? loopEndFrame,
    required int frameCount,
  }) {
    return _LoopMarkerDraft(
      loopStartFrame: loopStartFrame ?? this.loopStartFrame,
      loopEndFrame: loopEndFrame ?? this.loopEndFrame,
    ).clamped(frameCount);
  }

  _LoopMarkerDraft snappedToZeroCrossings(WavOverview waveform) {
    final radius = math.max(32, waveform.sampleRate ~/ 100);
    return _LoopMarkerDraft(
      loopStartFrame: waveform.nearestZeroCrossing(
        loopStartFrame,
        searchRadius: radius,
      ),
      loopEndFrame: waveform.nearestZeroCrossing(
        loopEndFrame,
        searchRadius: radius,
      ),
    ).clamped(waveform.frameCount);
  }

  @override
  bool operator ==(Object other) {
    return other is _LoopMarkerDraft &&
        other.loopStartFrame == loopStartFrame &&
        other.loopEndFrame == loopEndFrame;
  }

  @override
  int get hashCode => Object.hash(loopStartFrame, loopEndFrame);
}

enum _WaveformMode { metadata, destructive }

class _WavEditDraft {
  const _WavEditDraft({
    required this.trimStartFrame,
    required this.trimEndFrame,
    this.fadeInMs = 0,
    this.fadeOutMs = 0,
    this.fadeInCurve = WavFadeCurve.linear,
    this.fadeOutCurve = WavFadeCurve.linear,
    this.gainDb = 0,
    this.normalizePeakDb,
  });

  final int trimStartFrame;
  final int trimEndFrame;
  final int fadeInMs;
  final int fadeOutMs;
  final WavFadeCurve fadeInCurve;
  final WavFadeCurve fadeOutCurve;
  final double gainDb;
  final double? normalizePeakDb;

  factory _WavEditDraft.fromWaveform(WavOverview waveform) {
    return _WavEditDraft(
      trimStartFrame: 0,
      trimEndFrame: math.max(0, waveform.frameCount - 1),
    );
  }

  _WavEditDraft copyWith({
    int? trimStartFrame,
    int? trimEndFrame,
    int? fadeInMs,
    int? fadeOutMs,
    WavFadeCurve? fadeInCurve,
    WavFadeCurve? fadeOutCurve,
    double? gainDb,
    double? normalizePeakDb,
    bool clearNormalize = false,
  }) {
    return _WavEditDraft(
      trimStartFrame: trimStartFrame ?? this.trimStartFrame,
      trimEndFrame: trimEndFrame ?? this.trimEndFrame,
      fadeInMs: fadeInMs ?? this.fadeInMs,
      fadeOutMs: fadeOutMs ?? this.fadeOutMs,
      fadeInCurve: fadeInCurve ?? this.fadeInCurve,
      fadeOutCurve: fadeOutCurve ?? this.fadeOutCurve,
      gainDb: gainDb ?? this.gainDb,
      normalizePeakDb: clearNormalize
          ? null
          : normalizePeakDb ?? this.normalizePeakDb,
    );
  }

  _WavEditDraft clamped(WavOverview waveform) {
    final maxFrame = math.max(0, waveform.frameCount - 1);
    final start = trimStartFrame.clamp(0, maxFrame).toInt();
    final end = trimEndFrame.clamp(start, maxFrame).toInt();
    final maxMs = (waveform.durationSeconds * 1000).floor();
    return copyWith(
      trimStartFrame: start,
      trimEndFrame: end,
      fadeInMs: fadeInMs.clamp(0, maxMs).toInt(),
      fadeOutMs: fadeOutMs.clamp(0, maxMs).toInt(),
      gainDb: gainDb.clamp(-60.0, 24.0).toDouble(),
    );
  }

  WavRenderOptions toRenderOptions(WavOverview waveform) {
    final draft = clamped(waveform);
    return WavRenderOptions(
      trimStartFrame: draft.trimStartFrame,
      trimEndFrame: draft.trimEndFrame,
      fadeInFrames: _msToFrames(draft.fadeInMs, waveform.sampleRate),
      fadeOutFrames: _msToFrames(draft.fadeOutMs, waveform.sampleRate),
      fadeInCurve: draft.fadeInCurve,
      fadeOutCurve: draft.fadeOutCurve,
      gainDb: draft.gainDb,
      normalizePeakDb: draft.normalizePeakDb,
    );
  }

  static int _msToFrames(int ms, int sampleRate) {
    if (ms <= 0 || sampleRate <= 0) return 0;
    return ((ms / 1000) * sampleRate).round();
  }
}

class _WaveformSection extends StatelessWidget {
  const _WaveformSection({
    required this.waveform,
    required this.cachedWaveform,
    required this.mode,
    required this.canPreviewAudio,
    required this.isPreviewPlaying,
    required this.loopPreviewEnabled,
    required this.unavailableMessage,
    required this.loopDraft,
    required this.loopEnabled,
    required this.loopDirty,
    required this.savingLoop,
    required this.wavEditDraft,
    required this.renderingWav,
    required this.onChangeMode,
    required this.onChanged,
    required this.onChangeLoopEnabled,
    required this.onChangeWavEdit,
    required this.onSaveLoop,
    required this.onSaveWav,
    required this.onSaveWavAs,
    required this.onTogglePreview,
    required this.onToggleLoopPreview,
  });

  final Future<WavOverview?>? waveform;
  final WavOverview? cachedWaveform;
  final _WaveformMode mode;
  final bool canPreviewAudio;
  final bool isPreviewPlaying;
  final bool loopPreviewEnabled;
  final String? unavailableMessage;
  final _LoopMarkerDraft? loopDraft;
  final bool loopEnabled;
  final bool loopDirty;
  final bool savingLoop;
  final _WavEditDraft? wavEditDraft;
  final bool renderingWav;
  final ValueChanged<_WaveformMode> onChangeMode;
  final ValueChanged<_LoopMarkerDraft> onChanged;
  final ValueChanged<bool> onChangeLoopEnabled;
  final ValueChanged<_WavEditDraft> onChangeWavEdit;
  final Future<void> Function()? onSaveLoop;
  final Future<void> Function()? onSaveWav;
  final Future<void> Function()? onSaveWavAs;
  final Future<void> Function() onTogglePreview;
  final Future<void> Function(bool enabled) onToggleLoopPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final future = waveform;
    final canLoopPreview =
        canPreviewAudio && (mode == _WaveformMode.destructive || loopEnabled);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Waveform', style: theme.textTheme.titleSmall),
            ),
            Tooltip(
              message: canPreviewAudio
                  ? (isPreviewPlaying ? 'Stop sample preview' : 'Play sample')
                  : 'Audio preview needs a local or mounted WAV',
              child: IconButton(
                onPressed: canPreviewAudio ? onTogglePreview : null,
                icon: Icon(isPreviewPlaying ? Icons.stop : Icons.play_arrow),
              ),
            ),
            SizedBox(
              width: 132,
              child: Tooltip(
                message: canPreviewAudio
                    ? 'Continuously audition current edit'
                    : 'Loop preview needs a local or mounted WAV',
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        'Preview loop',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: canLoopPreview
                              ? colorScheme.onSurfaceVariant
                              : colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.48,
                                ),
                        ),
                      ),
                    ),
                    Switch(
                      value: canLoopPreview && loopPreviewEnabled,
                      onChanged: canLoopPreview ? onToggleLoopPreview : null,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<_WaveformMode>(
          segments: const [
            ButtonSegment(
              value: _WaveformMode.metadata,
              label: Text('Metadata'),
              icon: Icon(Icons.bookmark_border),
            ),
            ButtonSegment(
              value: _WaveformMode.destructive,
              label: Text('Destructive'),
              icon: Icon(Icons.content_cut),
            ),
          ],
          selected: {mode},
          onSelectionChanged: (value) => onChangeMode(value.first),
        ),
        const SizedBox(height: 8),
        FutureBuilder<WavOverview?>(
          future: future,
          initialData: cachedWaveform,
          builder: (context, snapshot) {
            final overview = snapshot.data;
            if (future == null) {
              return _WaveformUnavailable(
                message: unavailableMessage ?? 'No sample selected',
              );
            }
            if (overview == null &&
                snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 170,
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            if (overview == null) {
              return const _WaveformUnavailable(
                message: 'Waveform unavailable for this sample',
              );
            }
            final loopMarkers =
                loopDraft ?? _LoopMarkerDraft.fromWaveform(overview);
            final editDraft =
                (wavEditDraft ?? _WavEditDraft.fromWaveform(overview)).clamped(
                  overview,
                );
            final editorMarkers = mode == _WaveformMode.metadata
                ? loopMarkers
                : _LoopMarkerDraft(
                    loopStartFrame: editDraft.trimStartFrame,
                    loopEndFrame: editDraft.trimEndFrame,
                  );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 170,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.34,
                      ),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: _WaveformEditor(
                      waveform: overview,
                      markers: editorMarkers,
                      colorScheme: colorScheme,
                      destructivePreview: mode == _WaveformMode.destructive
                          ? editDraft
                          : null,
                      snapToZero: mode == _WaveformMode.metadata,
                      startLabel: mode == _WaveformMode.metadata
                          ? 'LS'
                          : 'Start',
                      endLabel: mode == _WaveformMode.metadata ? 'LE' : 'End',
                      onChanged: (markers) {
                        if (mode == _WaveformMode.metadata) {
                          onChanged(markers);
                        } else {
                          onChangeWavEdit(
                            editDraft.copyWith(
                              trimStartFrame: markers.loopStartFrame,
                              trimEndFrame: markers.loopEndFrame,
                            ),
                          );
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (mode == _WaveformMode.metadata)
                  _MetadataWaveformControls(
                    overview: overview,
                    markers: loopMarkers,
                    loopEnabled: loopEnabled,
                    loopDirty: loopDirty,
                    savingLoop: savingLoop,
                    onChanged: onChanged,
                    onChangeLoopEnabled: onChangeLoopEnabled,
                    onSaveLoop: onSaveLoop,
                  )
                else
                  _DestructiveWaveformControls(
                    overview: overview,
                    draft: editDraft,
                    renderingWav: renderingWav,
                    onChanged: onChangeWavEdit,
                    onSaveWav: onSaveWav,
                    onSaveWavAs: onSaveWavAs,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _WaveformUnavailable extends StatelessWidget {
  const _WaveformUnavailable({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 170,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.34),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: _WaveformMessage(text: message),
      ),
    );
  }
}

class _MetadataWaveformControls extends StatelessWidget {
  const _MetadataWaveformControls({
    required this.overview,
    required this.markers,
    required this.loopEnabled,
    required this.loopDirty,
    required this.savingLoop,
    required this.onChanged,
    required this.onChangeLoopEnabled,
    required this.onSaveLoop,
  });

  final WavOverview overview;
  final _LoopMarkerDraft markers;
  final bool loopEnabled;
  final bool loopDirty;
  final bool savingLoop;
  final ValueChanged<_LoopMarkerDraft> onChanged;
  final ValueChanged<bool> onChangeLoopEnabled;
  final Future<void> Function()? onSaveLoop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final maxFrame = math.max(1, overview.frameCount - 1).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Loop points',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Loop', style: theme.textTheme.labelMedium),
                Switch(
                  value: loopEnabled,
                  onChanged: savingLoop ? null : onChangeLoopEnabled,
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 4),
        RangeSlider(
          values: RangeValues(
            markers.loopStartFrame.clamp(0, maxFrame).toDouble(),
            markers.loopEndFrame.clamp(0, maxFrame).toDouble(),
          ),
          min: 0,
          max: maxFrame,
          onChanged: loopEnabled
              ? (values) => onChanged(
                  _LoopMarkerDraft(
                    loopStartFrame: values.start.round(),
                    loopEndFrame: values.end.round(),
                  ).snappedToZeroCrossings(overview),
                )
              : null,
        ),
        if (loopEnabled)
          _LoopFineControls(
            startLabel: 'Loop start',
            endLabel: 'Loop end',
            markers: markers,
            waveform: overview,
            snapToZero: true,
            onChanged: onChanged,
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: savingLoop ? null : onSaveLoop,
          icon: Icon(savingLoop ? Icons.hourglass_top : Icons.save, size: 16),
          label: Text(savingLoop ? 'Saving metadata...' : 'Save metadata'),
        ),
        const SizedBox(height: 4),
        Text(
          '${overview.frameCount} frames, '
          '${overview.durationSeconds.toStringAsFixed(2)}s. '
          'Metadata mode edits WAV smpl loop points only.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _DestructiveWaveformControls extends StatelessWidget {
  const _DestructiveWaveformControls({
    required this.overview,
    required this.draft,
    required this.renderingWav,
    required this.onChanged,
    required this.onSaveWav,
    required this.onSaveWavAs,
  });

  final WavOverview overview;
  final _WavEditDraft draft;
  final bool renderingWav;
  final ValueChanged<_WavEditDraft> onChanged;
  final Future<void> Function()? onSaveWav;
  final Future<void> Function()? onSaveWavAs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final maxFrame = math.max(1, overview.frameCount - 1).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RangeSlider(
          values: RangeValues(
            draft.trimStartFrame.clamp(0, maxFrame).toDouble(),
            draft.trimEndFrame.clamp(0, maxFrame).toDouble(),
          ),
          min: 0,
          max: maxFrame,
          onChanged: (values) => onChanged(
            draft.copyWith(
              trimStartFrame: values.start.round(),
              trimEndFrame: values.end.round(),
            ),
          ),
        ),
        _LoopFineControls(
          startLabel: 'Start',
          endLabel: 'End',
          markers: _LoopMarkerDraft(
            loopStartFrame: draft.trimStartFrame,
            loopEndFrame: draft.trimEndFrame,
          ),
          waveform: overview,
          snapToZero: true,
          onChanged: (markers) => onChanged(
            draft.copyWith(
              trimStartFrame: markers.loopStartFrame,
              trimEndFrame: markers.loopEndFrame,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _MsSlider(
          label: 'Fade in',
          overview: overview,
          value: draft.fadeInMs,
          onChanged: (value) => onChanged(draft.copyWith(fadeInMs: value)),
        ),
        _MsSlider(
          label: 'Fade out',
          overview: overview,
          value: draft.fadeOutMs,
          reverse: true,
          onChanged: (value) => onChanged(draft.copyWith(fadeOutMs: value)),
        ),
        const SizedBox(height: 8),
        _FadeCurvePicker(
          label: 'Fade in curve',
          value: draft.fadeInCurve,
          onChanged: (value) => onChanged(draft.copyWith(fadeInCurve: value)),
        ),
        const SizedBox(height: 8),
        _FadeCurvePicker(
          label: 'Fade out curve',
          value: draft.fadeOutCurve,
          onChanged: (value) => onChanged(draft.copyWith(fadeOutCurve: value)),
        ),
        const SizedBox(height: 12),
        Text('Gain', style: theme.textTheme.labelMedium),
        Slider(
          value: _gainDbToLinear(draft.gainDb),
          min: 0,
          max: 2,
          divisions: 200,
          label: '${_gainDbToLinear(draft.gainDb).toStringAsFixed(2)}x',
          onChanged: (value) =>
              onChanged(draft.copyWith(gainDb: _linearGainToDb(value))),
        ),
        Row(
          children: [
            Text(
              '${_gainDbToLinear(draft.gainDb).toStringAsFixed(2)}x '
              '(${draft.gainDb.toStringAsFixed(1)} dB)',
              style: theme.textTheme.bodySmall,
            ),
            const Spacer(),
            FilterChip(
              label: const Text('Normalize -1 dB'),
              selected: draft.normalizePeakDb != null,
              onSelected: (selected) => onChanged(
                draft.copyWith(
                  normalizePeakDb: selected ? -1 : null,
                  clearNormalize: !selected,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: renderingWav ? null : onSaveWav,
                icon: Icon(
                  renderingWav ? Icons.hourglass_top : Icons.save,
                  size: 16,
                ),
                label: Text(renderingWav ? 'Saving...' : 'Save'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: renderingWav ? null : onSaveWavAs,
                icon: const Icon(Icons.save_as, size: 16),
                label: const Text('Save as'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Destructive mode rewrites audio: trim start/end, fades, gain, and normalize.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _WaveformMessage extends StatelessWidget {
  const _WaveformMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _LoopHandle { start, end }

class _WaveformEditor extends StatefulWidget {
  const _WaveformEditor({
    required this.waveform,
    required this.markers,
    required this.colorScheme,
    required this.destructivePreview,
    required this.snapToZero,
    required this.startLabel,
    required this.endLabel,
    required this.onChanged,
  });

  final WavOverview waveform;
  final _LoopMarkerDraft markers;
  final ColorScheme colorScheme;
  final _WavEditDraft? destructivePreview;
  final bool snapToZero;
  final String startLabel;
  final String endLabel;
  final ValueChanged<_LoopMarkerDraft> onChanged;

  @override
  State<_WaveformEditor> createState() => _WaveformEditorState();
}

class _WaveformEditorState extends State<_WaveformEditor> {
  _LoopHandle? _activeHandle;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final handle = _nearestHandle(details.localPosition.dx, size.width);
            _moveHandle(handle, details.localPosition.dx, size.width);
          },
          onPanStart: (details) {
            _activeHandle = _nearestHandle(
              details.localPosition.dx,
              size.width,
            );
            _moveHandle(_activeHandle!, details.localPosition.dx, size.width);
          },
          onPanUpdate: (details) {
            final handle = _activeHandle;
            if (handle == null) return;
            _moveHandle(handle, details.localPosition.dx, size.width);
          },
          onPanEnd: (_) => _activeHandle = null,
          onPanCancel: () => _activeHandle = null,
          child: CustomPaint(
            painter: _WaveformPainter(
              waveform: widget.waveform,
              markers: widget.markers,
              colorScheme: widget.colorScheme,
              destructivePreview: widget.destructivePreview,
              startLabel: widget.startLabel,
              endLabel: widget.endLabel,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }

  _LoopHandle _nearestHandle(double x, double width) {
    final startX = _frameX(widget.markers.loopStartFrame, width);
    final endX = _frameX(widget.markers.loopEndFrame, width);
    return (x - startX).abs() <= (x - endX).abs()
        ? _LoopHandle.start
        : _LoopHandle.end;
  }

  void _moveHandle(_LoopHandle handle, double x, double width) {
    final rawFrame = _frameFromX(x, width);
    final frame = widget.snapToZero ? _snapFrame(rawFrame) : rawFrame;
    final next = switch (handle) {
      _LoopHandle.start => widget.markers.copyWith(
        loopStartFrame: math.min(frame, widget.markers.loopEndFrame),
        frameCount: widget.waveform.frameCount,
      ),
      _LoopHandle.end => widget.markers.copyWith(
        loopEndFrame: math.max(frame, widget.markers.loopStartFrame),
        frameCount: widget.waveform.frameCount,
      ),
    };
    widget.onChanged(next);
  }

  int _snapFrame(int frame) {
    final radius = math.max(32, widget.waveform.sampleRate ~/ 100);
    return widget.waveform.nearestZeroCrossing(frame, searchRadius: radius);
  }

  int _frameFromX(double x, double width) {
    final maxFrame = math.max(1, widget.waveform.frameCount - 1);
    final ratio = width <= 0 ? 0.0 : (x / width).clamp(0.0, 1.0);
    return (ratio * maxFrame).round();
  }

  double _frameX(int frame, double width) {
    final maxFrame = math.max(1, widget.waveform.frameCount - 1);
    return (frame.clamp(0, maxFrame) / maxFrame) * width;
  }
}

class _LoopFineControls extends StatelessWidget {
  const _LoopFineControls({
    required this.startLabel,
    required this.endLabel,
    required this.markers,
    required this.waveform,
    required this.snapToZero,
    required this.onChanged,
  });

  final String startLabel;
  final String endLabel;
  final _LoopMarkerDraft markers;
  final WavOverview waveform;
  final bool snapToZero;
  final ValueChanged<_LoopMarkerDraft> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _LoopFineRow(
          label: startLabel,
          value: markers.loopStartFrame,
          onNudge: (delta) => _changeStart(delta),
          onSnap: snapToZero ? () => _snapStart() : null,
        ),
        _LoopFineRow(
          label: endLabel,
          value: markers.loopEndFrame,
          onNudge: (delta) => _changeEnd(delta),
          onSnap: snapToZero ? () => _snapEnd() : null,
        ),
      ],
    );
  }

  void _changeStart(int delta) {
    onChanged(
      markers.copyWith(
        loopStartFrame: markers.loopStartFrame + delta,
        frameCount: waveform.frameCount,
      ),
    );
  }

  void _changeEnd(int delta) {
    onChanged(
      markers.copyWith(
        loopEndFrame: markers.loopEndFrame + delta,
        frameCount: waveform.frameCount,
      ),
    );
  }

  void _snapStart() {
    onChanged(
      markers.copyWith(
        loopStartFrame: waveform.nearestZeroCrossing(markers.loopStartFrame),
        frameCount: waveform.frameCount,
      ),
    );
  }

  void _snapEnd() {
    onChanged(
      markers.copyWith(
        loopEndFrame: waveform.nearestZeroCrossing(markers.loopEndFrame),
        frameCount: waveform.frameCount,
      ),
    );
  }
}

class _LoopFineRow extends StatelessWidget {
  const _LoopFineRow({
    required this.label,
    required this.value,
    required this.onNudge,
    this.onSnap,
  });

  final String label;
  final int value;
  final ValueChanged<int> onNudge;
  final VoidCallback? onSnap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          _TinyNudgeButton(label: '-100', onPressed: () => onNudge(-100)),
          _TinyNudgeButton(label: '-1', onPressed: () => onNudge(-1)),
          Expanded(
            child: Center(
              child: Text(
                value.toString(),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          _TinyNudgeButton(label: '+1', onPressed: () => onNudge(1)),
          _TinyNudgeButton(label: '+100', onPressed: () => onNudge(100)),
          TextButton(onPressed: onSnap, child: const Text('Zero')),
        ],
      ),
    );
  }
}

class _MsSlider extends StatelessWidget {
  const _MsSlider({
    required this.label,
    required this.overview,
    required this.value,
    required this.onChanged,
    this.reverse = false,
  });

  final String label;
  final WavOverview overview;
  final int value;
  final ValueChanged<int> onChanged;
  final bool reverse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxMs = math.max(1, (overview.durationSeconds * 1000).round());
    final sliderMax = math.min(maxMs, 10000).toDouble();
    final clamped = value.clamp(0, sliderMax).toDouble();
    final sliderValue = reverse ? sliderMax - clamped : clamped;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(label, style: theme.textTheme.labelMedium),
              const Spacer(),
              Text(
                '$value ms',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          Slider(
            value: sliderValue,
            min: 0,
            max: sliderMax,
            divisions: sliderMax.round(),
            label: '$value ms',
            onChanged: (next) =>
                onChanged((reverse ? sliderMax - next : next).round()),
          ),
        ],
      ),
    );
  }
}

class _FadeCurvePicker extends StatelessWidget {
  const _FadeCurvePicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final WavFadeCurve value;
  final ValueChanged<WavFadeCurve> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final curve in WavFadeCurve.values)
              _FadeCurveButton(
                curve: curve,
                selected: curve == value,
                onTap: () => onChanged(curve),
              ),
          ],
        ),
      ],
    );
  }
}

class _FadeCurveButton extends StatelessWidget {
  const _FadeCurveButton({
    required this.curve,
    required this.selected,
    required this.onTap,
  });

  final WavFadeCurve curve;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 72,
        height: 54,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          border: Border.all(
            color: selected ? colorScheme.primary : colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          children: [
            Expanded(
              child: CustomPaint(
                painter: _FadeCurvePainter(
                  curve: curve,
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                child: const SizedBox.expand(),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _fadeCurveLabel(curve),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

double _gainDbToLinear(double db) {
  return math.pow(10, db / 20).toDouble().clamp(0.0, 2.0);
}

double _linearGainToDb(double gain) {
  if (gain <= 0) return -60;
  return (20 * math.log(gain) / math.ln10).clamp(-60.0, 24.0).toDouble();
}

class _FadeCurvePainter extends CustomPainter {
  const _FadeCurvePainter({required this.curve, required this.color});

  final WavFadeCurve curve;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    for (var i = 0; i <= 32; i++) {
      final x = i / 32;
      final y = _curveValue(x);
      final point = Offset(x * size.width, (1 - y) * size.height);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  double _curveValue(double x) {
    return switch (curve) {
      WavFadeCurve.linear => x,
      WavFadeCurve.equalPower => math.sin(x * math.pi / 2),
      WavFadeCurve.exponential => x * x,
      WavFadeCurve.sCurve => x * x * (3 - 2 * x),
    };
  }

  @override
  bool shouldRepaint(covariant _FadeCurvePainter oldDelegate) {
    return oldDelegate.curve != curve || oldDelegate.color != color;
  }
}

String _fadeCurveLabel(WavFadeCurve curve) {
  return switch (curve) {
    WavFadeCurve.linear => 'Linear',
    WavFadeCurve.equalPower => 'Equal',
    WavFadeCurve.exponential => 'Expo',
    WavFadeCurve.sCurve => 'S',
  };
}

class _TinyNudgeButton extends StatelessWidget {
  const _TinyNudgeButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 28,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          textStyle: Theme.of(context).textTheme.labelSmall,
        ),
        child: Text(label),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.waveform,
    required this.markers,
    required this.colorScheme,
    required this.destructivePreview,
    required this.startLabel,
    required this.endLabel,
  });

  final WavOverview waveform;
  final _LoopMarkerDraft markers;
  final ColorScheme colorScheme;
  final _WavEditDraft? destructivePreview;
  final String startLabel;
  final String endLabel;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final path = Path();
    final peaks = waveform.peaks;
    if (peaks.isEmpty) return;

    for (var i = 0; i < peaks.length; i++) {
      final x = peaks.length == 1 ? 0.0 : (i / (peaks.length - 1)) * size.width;
      final y = centerY + peaks[i].max * centerY * -0.82;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    for (var i = peaks.length - 1; i >= 0; i--) {
      final x = peaks.length == 1 ? 0.0 : (i / (peaks.length - 1)) * size.width;
      final y = centerY + peaks[i].min * centerY * -0.82;
      path.lineTo(x, y);
    }
    path.close();

    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      Paint()
        ..color = colorScheme.outlineVariant.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );
    canvas.drawPath(
      path,
      Paint()..color = colorScheme.primary.withValues(alpha: 0.56),
    );

    final preview = destructivePreview;
    if (preview != null) {
      _drawDestructivePreview(canvas, size, preview);
    }

    _drawRange(
      canvas,
      size,
      markers.loopStartFrame,
      markers.loopEndFrame,
      colorScheme.secondary.withValues(alpha: 0.14),
    );
    _drawMarker(
      canvas,
      size,
      markers.loopStartFrame,
      colorScheme.secondary,
      startLabel,
    );
    _drawMarker(
      canvas,
      size,
      markers.loopEndFrame,
      colorScheme.secondary,
      endLabel,
    );
  }

  void _drawDestructivePreview(Canvas canvas, Size size, _WavEditDraft draft) {
    final startX = _frameX(draft.trimStartFrame, size.width);
    final endX = _frameX(draft.trimEndFrame, size.width);
    if (endX <= startX) return;
    final fadeInFrames = _WavEditDraft._msToFrames(
      draft.fadeInMs,
      waveform.sampleRate,
    );
    final fadeOutFrames = _WavEditDraft._msToFrames(
      draft.fadeOutMs,
      waveform.sampleRate,
    );
    final fadeInX = _frameX(
      draft.trimStartFrame + fadeInFrames,
      size.width,
    ).clamp(startX, endX);
    final fadeOutX = _frameX(
      draft.trimEndFrame - fadeOutFrames + 1,
      size.width,
    ).clamp(startX, endX);
    final gain = math.pow(10, draft.gainDb / 20).toDouble().clamp(0.0, 2.0);
    final baselineY = size.height - 10;
    final gainY = (size.height / 2) * (1 - (gain / 2));

    final fillPaint = Paint()
      ..color = colorScheme.tertiary.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;
    canvas.drawRect(Rect.fromLTRB(startX, 0, endX, size.height), fillPaint);

    final paint = Paint()
      ..color = colorScheme.tertiary.withValues(alpha: 0.85)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(startX, baselineY);
    _appendFadeCurve(
      path,
      startX: startX,
      endX: fadeInX,
      fromY: baselineY,
      toY: gainY,
      curve: draft.fadeInCurve,
      reverse: false,
    );
    path.lineTo(fadeOutX, gainY);
    _appendFadeCurve(
      path,
      startX: fadeOutX,
      endX: endX,
      fromY: gainY,
      toY: baselineY,
      curve: draft.fadeOutCurve,
      reverse: true,
    );
    canvas.drawPath(path, paint);
  }

  void _appendFadeCurve(
    Path path, {
    required double startX,
    required double endX,
    required double fromY,
    required double toY,
    required WavFadeCurve curve,
    required bool reverse,
  }) {
    if ((endX - startX).abs() < 0.5) {
      path.lineTo(endX, toY);
      return;
    }
    const steps = 24;
    for (var step = 1; step <= steps; step++) {
      final t = step / steps;
      final shaped = _fadePreviewCurve(reverse ? 1 - t : t, curve);
      final y = reverse
          ? _lerpDouble(fromY, toY, 1 - shaped)
          : _lerpDouble(fromY, toY, shaped);
      path.lineTo(_lerpDouble(startX, endX, t), y);
    }
  }

  double _fadePreviewCurve(double value, WavFadeCurve curve) {
    final x = value.clamp(0.0, 1.0);
    return switch (curve) {
      WavFadeCurve.linear => x,
      WavFadeCurve.equalPower => math.sin(x * math.pi / 2),
      WavFadeCurve.exponential => x * x,
      WavFadeCurve.sCurve => x * x * (3 - 2 * x),
    };
  }

  double _lerpDouble(double a, double b, double t) {
    return a + (b - a) * t;
  }

  void _drawRange(Canvas canvas, Size size, int start, int end, Color color) {
    final x0 = _frameX(start, size.width);
    final x1 = _frameX(end, size.width);
    canvas.drawRect(
      Rect.fromLTRB(x0, 0, x1, size.height),
      Paint()..color = color,
    );
  }

  void _drawMarker(
    Canvas canvas,
    Size size,
    int frame,
    Color color,
    String label,
  ) {
    final x = _frameX(frame, size.width);
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = color
        ..strokeWidth = 2,
    );
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final labelX = (x + 4).clamp(2.0, size.width - painter.width - 2);
    painter.paint(canvas, Offset(labelX, 4));
  }

  double _frameX(int frame, double width) {
    final maxFrame = math.max(1, waveform.frameCount - 1);
    return (frame.clamp(0, maxFrame) / maxFrame) * width;
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.waveform != waveform ||
        oldDelegate.markers != markers ||
        oldDelegate.colorScheme != colorScheme ||
        oldDelegate.destructivePreview != destructivePreview ||
        oldDelegate.startLabel != startLabel ||
        oldDelegate.endLabel != endLabel;
  }
}

class _KeyboardMapPainter extends CustomPainter {
  _KeyboardMapPainter({
    required this.regions,
    required this.selected,
    required this.lanes,
    required this.minMidi,
    required this.maxMidi,
    required this.mapRevision,
    required this.colorScheme,
  });

  final List<PolySampleRegion> regions;
  final PolySampleRegion? selected;
  final List<_SampleLane> lanes;
  final int minMidi;
  final int maxMidi;
  final int mapRevision;
  final ColorScheme colorScheme;

  @override
  void paint(Canvas canvas, Size size) {
    final sortedLanes = _displaySampleLanes(regions, lanes);
    final left = sortedLanes.length > 1 ? 58.0 : 18.0;
    final right = size.width - 18.0;
    final width = math.max(1.0, right - left);
    const labelHeight = 26.0;
    const keyboardHeight = 36.0;
    const bottomPadding = 8.0;
    final zoneTop = labelHeight;
    final zoneBottom = size.height - keyboardHeight - bottomPadding;
    final zoneHeight = math.max(22.0, zoneBottom - zoneTop);
    final laneHeight = zoneHeight / sortedLanes.length;
    final keyboardTop = zoneBottom;
    final keyboardBottom = size.height - bottomPadding;
    final whiteKeyRect = Rect.fromLTRB(
      left,
      keyboardTop,
      right,
      keyboardBottom,
    );
    final gridPaint = Paint()
      ..color = colorScheme.outlineVariant.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    final softGridPaint = Paint()
      ..color = colorScheme.outlineVariant.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    final keyboardBase = Paint()
      ..color = colorScheme.surfaceContainerHighest.withValues(alpha: 0.10);

    for (var i = 0; i < sortedLanes.length; i++) {
      final lane = sortedLanes[i];
      final laneTop = zoneTop + i * laneHeight;
      final laneBottom = laneTop + laneHeight;
      if (i.isOdd) {
        canvas.drawRect(
          Rect.fromLTRB(0, laneTop, size.width, laneBottom),
          Paint()
            ..color = colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.12,
            ),
        );
      }
      if (sortedLanes.length > 1) {
        final labelPainter = TextPainter(
          text: TextSpan(
            text: lane.label,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        labelPainter.paint(
          canvas,
          Offset(10, laneTop + (laneHeight - labelPainter.height) / 2),
        );
      }
      canvas.drawLine(
        Offset(left, laneBottom),
        Offset(right, laneBottom),
        softGridPaint,
      );
    }

    for (var midi = minMidi; midi < maxMidi; midi += 12) {
      final x = left + ((midi - minMidi) / (maxMidi - minMidi)) * width;
      canvas.drawLine(Offset(x, zoneTop), Offset(x, keyboardBottom), gridPaint);
    }

    final zones = _mapZonesFor(regions);
    for (final zone in zones) {
      final layerIndex = sortedLanes.indexOf(zone.lane);
      final lane = layerIndex < 0 ? 0 : layerIndex;
      final range = zone.range;
      final x0 = left + ((range.start - minMidi) / (maxMidi - minMidi)) * width;
      final x1 =
          left + ((range.end + 1 - minMidi) / (maxMidi - minMidi)) * width;
      final y0 = zoneTop + lane * laneHeight;
      final y1 = y0 + laneHeight;
      final selectedRegion = zone.contains(selected);
      final rect = Rect.fromLTRB(x0 + 1, y0 + 1, x1 - 1, y1 - 1);
      canvas.drawRect(
        rect,
        Paint()
          ..color = selectedRegion
              ? colorScheme.tertiary.withValues(alpha: 0.66)
              : colorScheme.primary.withValues(alpha: 0.36),
      );
      if (selectedRegion) {
        canvas.drawRect(
          rect.deflate(1),
          Paint()
            ..color = colorScheme.onSurface
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      if (rect.width > 14 && rect.height > 14) {
        final label = rect.width >= 46 ? zone.label : zone.compactLabel;
        final labelPainter = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              color: selectedRegion
                  ? Colors.black.withValues(alpha: 0.88)
                  : colorScheme.onSurface.withValues(alpha: 0.82),
              fontSize: rect.width >= 46 ? (selectedRegion ? 10 : 9) : 8,
              fontWeight: selectedRegion ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          maxLines: 1,
          ellipsis: '...',
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: rect.width - 8);
        canvas.save();
        canvas.clipRect(rect.deflate(3));
        labelPainter.paint(
          canvas,
          Offset(
            rect.left + 4,
            rect.top + (rect.height - labelPainter.height) / 2,
          ),
        );
        canvas.restore();
      }
    }

    canvas.drawRect(whiteKeyRect, keyboardBase);

    for (var midi = minMidi; midi < maxMidi; midi++) {
      final x0 = left + ((midi - minMidi) / (maxMidi - minMidi)) * width;
      final x1 = left + ((midi + 1 - minMidi) / (maxMidi - minMidi)) * width;
      final note = midi % 12;
      final isBlack = _isBlackNote(note);
      if (isBlack) {
        continue;
      }
      final keyRect = Rect.fromLTRB(x0, keyboardTop, x1, keyboardBottom);
      final paint = Paint()
        ..color = colorScheme.onSurface.withValues(alpha: 0.78);
      canvas.drawRect(keyRect.deflate(0.75), paint);
      canvas.drawLine(
        Offset(keyRect.left, keyRect.top),
        Offset(keyRect.left, keyRect.bottom),
        gridPaint,
      );
    }

    for (var midi = minMidi; midi < maxMidi; midi++) {
      final note = midi % 12;
      final isBlack = _isBlackNote(note);
      if (!isBlack) {
        continue;
      }
      final x0 = left + ((midi - minMidi) / (maxMidi - minMidi)) * width;
      final x1 = left + ((midi + 1 - minMidi) / (maxMidi - minMidi)) * width;
      final center = (x0 + x1) / 2;
      final blackWidth = (x1 - x0) * 0.72;
      final keyRect = Rect.fromLTRB(
        center - blackWidth / 2,
        keyboardTop,
        center + blackWidth / 2,
        keyboardTop + ((keyboardBottom - keyboardTop) * 0.64),
      );
      final paint = Paint()
        ..color = colorScheme.surfaceContainerLowest.withValues(alpha: 0.98);
      canvas.drawRect(keyRect, paint);
      canvas.drawRect(keyRect, gridPaint);
    }

    final selectedRoot = selected?.rootMidi;
    if (selectedRoot != null) {
      final root = selectedRoot.clamp(minMidi, maxMidi - 1);
      final x0 = left + ((root - minMidi) / (maxMidi - minMidi)) * width;
      final x1 = left + ((root + 1 - minMidi) / (maxMidi - minMidi)) * width;
      final selectedPaint = Paint()
        ..color = colorScheme.tertiary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      canvas.drawRect(
        Rect.fromLTRB(x0, keyboardTop, x1, keyboardBottom).deflate(1.5),
        selectedPaint,
      );
    }

    for (var midi = minMidi; midi < maxMidi; midi += 12) {
      final x = left + ((midi - minMidi) / (maxMidi - minMidi)) * width;
      final textPainter = TextPainter(
        text: TextSpan(
          text: PolyMultisampleParser.midiToNoteName(midi),
          style: TextStyle(
            color: colorScheme.onSurfaceVariant,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(x + 3, 7));
    }
  }

  @override
  bool shouldRepaint(covariant _KeyboardMapPainter oldDelegate) {
    return oldDelegate.regions != regions ||
        oldDelegate.selected?.path != selected?.path ||
        oldDelegate.lanes != lanes ||
        oldDelegate.minMidi != minMidi ||
        oldDelegate.maxMidi != maxMidi ||
        oldDelegate.mapRevision != mapRevision ||
        oldDelegate.colorScheme != colorScheme;
  }

  bool _isBlackNote(int note) {
    return note == 1 || note == 3 || note == 6 || note == 8 || note == 10;
  }
}
