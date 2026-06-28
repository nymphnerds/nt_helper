import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

import 'poly_multisample_parser.dart';
import 'wav_metadata.dart';

class DecentSamplerConversionResult {
  const DecentSamplerConversionResult({
    required this.outputFolders,
    required this.copiedFiles,
    required this.warnings,
  });

  final List<String> outputFolders;
  final int copiedFiles;
  final List<String> warnings;

  String get summary {
    final folderCount = outputFolders.length;
    final warningText = warnings.isEmpty ? 'No warnings.' : '${warnings.length} warning(s).';
    return 'Converted $copiedFiles WAV file(s) into $folderCount folder(s). $warningText';
  }
}

class DecentSamplerConverter {
  static const _supportedInputExtensions = {'.dspreset', '.dslibrary', '.zip'};

  Future<DecentSamplerConversionResult> convert({
    required String sourcePath,
    required String outputParentPath,
  }) async {
    final extension = p.extension(sourcePath).toLowerCase();
    if (!_supportedInputExtensions.contains(extension)) {
      throw FormatException('Unsupported Decent source: $extension');
    }

    final sourceFile = File(sourcePath);
    final sourceName = p.basenameWithoutExtension(sourcePath);
    final warnings = <String>[];
    final plans = extension == '.dspreset'
        ? await _readDspreset(sourceFile, sourceName, warnings)
        : await _readArchive(sourceFile, sourceName, warnings);

    if (plans.isEmpty) {
      throw const FormatException('No Decent Sampler preset found.');
    }

    final outputFolders = <String>[];
    var copiedFiles = 0;
    for (final plan in plans) {
      final outputFolder = await _createOutputFolder(
        outputParentPath,
        plan.presetName,
      );
      outputFolders.add(outputFolder.path);
      copiedFiles += await _writePlan(plan, outputFolder, warnings);
      await _writeReport(plan, outputFolder, warnings);
    }

    return DecentSamplerConversionResult(
      outputFolders: outputFolders,
      copiedFiles: copiedFiles,
      warnings: warnings,
    );
  }

  Future<List<_DecentPresetPlan>> _readDspreset(
    File file,
    String fallbackName,
    List<String> warnings,
  ) async {
    final content = _fixInvalidXml(_decodeXmlText(await file.readAsBytes()));
    final preset = _parsePresetXml(
      content,
      presetName: fallbackName,
      warnings: warnings,
    );
    final baseDir = file.parent.path;
    return [
      preset.copyWith(
        sourceResolver: _LocalDecentSourceResolver(baseDirectory: baseDir),
      ),
    ];
  }

  Future<List<_DecentPresetPlan>> _readArchive(
    File file,
    String fallbackName,
    List<String> warnings,
  ) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    final files = archive.where((entry) => entry.isFile).toList();
    final presetFiles = files
        .where((entry) => entry.name.toLowerCase().endsWith('.dspreset'))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (presetFiles.isEmpty) {
      warnings.add('${p.basename(file.path)} contains no .dspreset file.');
      return const [];
    }

    final archiveFiles = {
      for (final entry in files) _normalizeZipPath(entry.name): entry,
    };
    final plans = <_DecentPresetPlan>[];
    for (final entry in presetFiles) {
      final content = _fixInvalidXml(_decodeXmlText(entry.content as List<int>));
      final presetName = p.posix.basenameWithoutExtension(entry.name);
      final preset = _parsePresetXml(
        content,
        presetName: presetName.isEmpty ? fallbackName : presetName,
        warnings: warnings,
      );
      plans.add(
        preset.copyWith(
          sourceResolver: _ArchiveDecentSourceResolver(
            files: archiveFiles,
            presetDirectory: p.posix.dirname(_normalizeZipPath(entry.name)),
          ),
        ),
      );
    }
    return plans;
  }

  _DecentPresetPlan _parsePresetXml(
    String content, {
    required String presetName,
    required List<String> warnings,
  }) {
    final sampleElements = _sampleAttributeMaps(content);
    if (sampleElements.isEmpty) {
      warnings.add('$presetName has no <sample> entries.');
    }

    final rawRegions = <_DecentRawRegion>[];
    for (final sample in sampleElements) {
      final samplePath = sample['path'];
      if (samplePath == null || samplePath.trim().isEmpty) {
        warnings.add('$presetName has a sample with no path.');
        continue;
      }
      final rootMidi = _parseNoteAttribute(sample['rootnote']);
      final lowMidi = _parseNoteAttribute(sample['lonote']);
      final highMidi = _parseNoteAttribute(sample['hinote']);
      final velocityLow = _parseIntAttribute(sample['lovel']) ?? 1;
      final velocityHigh = _parseIntAttribute(sample['hivel']) ?? 127;
      final seqPosition = _parseIntAttribute(sample['seqposition']);
      final loopStart = _parseIntAttribute(sample['loopstart']);
      final loopEnd = _parseIntAttribute(sample['loopend']);

      rawRegions.add(
        _DecentRawRegion(
          sourcePath: samplePath.trim(),
          rootMidi: rootMidi,
          lowMidi: lowMidi,
          highMidi: highMidi,
          velocityLow: velocityLow.clamp(1, 127).toInt(),
          velocityHigh: velocityHigh.clamp(1, 127).toInt(),
          seqPosition: seqPosition,
          loopStart: loopStart,
          loopEnd: loopEnd,
        ),
      );
    }

    return _DecentPresetPlan(
      presetName: _safeFileStem(presetName),
      regions: _mapRawRegions(rawRegions, presetName, warnings),
      sourceResolver: const _MissingDecentSourceResolver(),
    );
  }

  List<_DecentMappedRegion> _mapRawRegions(
    List<_DecentRawRegion> rawRegions,
    String presetName,
    List<String> warnings,
  ) {
    final velocityKeys = <String, List<_DecentRawRegion>>{};
    for (final region in rawRegions) {
      final root = region.rootMidi;
      if (root == null) {
        warnings.add('${p.basename(region.sourcePath)} has no rootNote.');
        continue;
      }
      final low = (region.lowMidi ?? root).clamp(0, 127).toInt();
      final key = '$root|$low|${region.highMidi ?? -1}';
      velocityKeys.putIfAbsent(key, () => []).add(region);
    }

    final velocityLayerByRegion = <_DecentRawRegion, int>{};
    for (final group in velocityKeys.values) {
      final ranges = group
          .map((region) => '${region.velocityLow}-${region.velocityHigh}')
          .toSet()
          .toList()
        ..sort((a, b) {
          final aLow = int.tryParse(a.split('-').first) ?? 1;
          final bLow = int.tryParse(b.split('-').first) ?? 1;
          return aLow.compareTo(bLow);
        });
      for (final region in group) {
        final key = '${region.velocityLow}-${region.velocityHigh}';
        velocityLayerByRegion[region] = ranges.indexOf(key) + 1;
      }
    }

    final rrCounters = <String, int>{};
    final outputNames = <String, int>{};
    final mapped = <_DecentMappedRegion>[];
    for (final region in rawRegions) {
      final root = region.rootMidi;
      if (root == null) continue;
      final low = (region.lowMidi ?? root).clamp(0, 127).toInt();
      final velocityLayer = velocityLayerByRegion[region] ?? 1;
      final velocityLayerCount = velocityKeys[
              '$root|$low|${region.highMidi ?? -1}']
          ?.map((candidate) => velocityLayerByRegion[candidate] ?? 1)
          .toSet()
          .length ??
          1;
      final rrKey = '$root|$low|$velocityLayer';
      final roundRobin =
          region.seqPosition ?? (rrCounters.update(rrKey, (v) => v + 1, ifAbsent: () => 1));
      final roundRobinCount = rawRegions.where((candidate) {
        return candidate.rootMidi == root &&
            (candidate.lowMidi ?? root).clamp(0, 127).toInt() == low &&
            (velocityLayerByRegion[candidate] ?? 1) == velocityLayer;
      }).length;
      final fileName = _targetFileName(
        presetName: presetName,
        rootMidi: root,
        switchPoint: low,
        velocityLayer: velocityLayer,
        writeVelocityLayer: velocityLayerCount > 1,
        roundRobin: roundRobin,
        writeRoundRobin: roundRobinCount > 1,
        outputNames: outputNames,
      );
      mapped.add(
        _DecentMappedRegion(
          sourcePath: region.sourcePath,
          outputFileName: fileName,
          rootMidi: root,
          switchPoint: low,
          velocityLayer: velocityLayer,
          roundRobin: roundRobin,
          loopStart: region.loopStart,
          loopEnd: region.loopEnd,
        ),
      );
    }
    return mapped;
  }

  Future<Directory> _createOutputFolder(
    String outputParentPath,
    String presetName,
  ) async {
    final parent = Directory(outputParentPath);
    await parent.create(recursive: true);
    var candidate = Directory(p.join(parent.path, presetName));
    if (!await candidate.exists()) {
      await candidate.create(recursive: true);
      return candidate;
    }
    for (var index = 2; index < 1000; index++) {
      candidate = Directory(p.join(parent.path, '${presetName}_$index'));
      if (!await candidate.exists()) {
        await candidate.create(recursive: true);
        return candidate;
      }
    }
    throw FileSystemException('Could not create output folder', parent.path);
  }

  Future<int> _writePlan(
    _DecentPresetPlan plan,
    Directory outputFolder,
    List<String> warnings,
  ) async {
    var copied = 0;
    for (final region in plan.regions) {
      final extension = p.extension(region.sourcePath).toLowerCase();
      if (extension != '.wav') {
        warnings.add(
          '${p.basename(region.sourcePath)} is $extension; WAV output only in this build.',
        );
        continue;
      }

      final bytes = await plan.sourceResolver.read(region.sourcePath);
      if (bytes == null) {
        warnings.add('Missing source sample: ${region.sourcePath}');
        continue;
      }

      var outputBytes = bytes;
      final loopStart = region.loopStart;
      final loopEnd = region.loopEnd;
      if (loopStart != null && loopEnd != null && loopEnd > loopStart) {
        try {
          outputBytes = WavMetadataWriter.writeSmplLoop(
            bytes,
            loopStart: loopStart,
            loopEnd: loopEnd,
          );
        } catch (e) {
          warnings.add(
            'Could not write loop metadata for ${p.basename(region.sourcePath)}: $e',
          );
        }
      }

      final outputFile = File(p.join(outputFolder.path, region.outputFileName));
      await outputFile.writeAsBytes(outputBytes, flush: true);
      copied++;
    }
    return copied;
  }

  Future<void> _writeReport(
    _DecentPresetPlan plan,
    Directory outputFolder,
    List<String> warnings,
  ) async {
    final lines = <String>[
      '# Decent Sampler Conversion Report',
      '',
      '- Preset: `${plan.presetName}`',
      '- Output folder: `${outputFolder.path}`',
      '- Regions planned: ${plan.regions.length}',
      '',
      '## Files',
      '',
      '| Source | Output | Root | Switch | Velocity | Round robin | Loop |',
      '| --- | --- | --- | --- | --- | --- | --- |',
      for (final region in plan.regions)
        '| `${region.sourcePath}` | `${region.outputFileName}` | ${PolyMultisampleParser.midiToNoteName(region.rootMidi)} | ${region.switchPoint} | V${region.velocityLayer} | RR${region.roundRobin} | ${region.loopStart != null && region.loopEnd != null ? '${region.loopStart}-${region.loopEnd}' : '-'} |',
      '',
      '## Warnings',
      '',
      if (warnings.isEmpty) '- None' else for (final warning in warnings) '- $warning',
      '',
    ];
    await File(
      p.join(outputFolder.path, '_CONVERSION_REPORT.md'),
    ).writeAsString(lines.join('\n'), flush: true);
  }

  String _targetFileName({
    required String presetName,
    required int rootMidi,
    required int switchPoint,
    required int velocityLayer,
    required bool writeVelocityLayer,
    required int roundRobin,
    required bool writeRoundRobin,
    required Map<String, int> outputNames,
  }) {
    final rootName = PolyMultisampleParser.midiToNoteName(rootMidi);
    final parts = <String>[_safeFileStem(presetName), rootName];
    if (switchPoint != rootMidi) {
      parts.add('SW$switchPoint');
    }
    if (writeVelocityLayer) {
      parts.add('V$velocityLayer');
    }
    if (writeRoundRobin) {
      parts.add('RR$roundRobin');
    }
    final stem = parts.join('_');
    final count = (outputNames[stem] ?? 0) + 1;
    outputNames[stem] = count;
    final uniqueStem = count == 1 ? stem : '${stem}_dup$count';
    return '$uniqueStem.wav';
  }

  static List<Map<String, String>> _sampleAttributeMaps(String content) {
    final document = html_parser.parse(content);
    final root = document.querySelector('decentsampler');
    final elements = root?.querySelectorAll('groups sample') ?? const <html_dom.Element>[];
    if (elements.isNotEmpty) {
      return elements.map(_elementAttributes).toList();
    }
    return _sampleTagsFromText(content).map(_tagAttributes).toList();
  }

  static Map<String, String> _elementAttributes(html_dom.Element element) {
    final attributes = <String, String>{};
    for (final entry in element.attributes.entries) {
      attributes[entry.key.toString().toLowerCase()] = entry.value;
    }
    return attributes;
  }

  static Iterable<String> _sampleTagsFromText(String content) {
    return RegExp(
      r'<\s*sample\b[^>]*>',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(content).map((match) => match.group(0) ?? '');
  }

  static Map<String, String> _tagAttributes(String tag) {
    final attributes = <String, String>{};
    final pattern = RegExp(
      r'''([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'=<>`]+))''',
      multiLine: true,
    );
    for (final match in pattern.allMatches(tag)) {
      final key = match.group(1)?.toLowerCase();
      final value = match.group(3) ?? match.group(4) ?? match.group(5) ?? '';
      if (key != null) attributes[key] = value;
    }
    return attributes;
  }

  static int? _parseIntAttribute(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return double.tryParse(value.trim())?.round();
  }

  static int? _parseNoteAttribute(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final trimmed = value.trim();
    return int.tryParse(trimmed) ?? PolyMultisampleParser.noteNameToMidi(trimmed);
  }

  static String _fixInvalidXml(String content) {
    final headerStart = content.indexOf('<?xml');
    return headerStart > 0 ? content.substring(headerStart) : content;
  }

  static String _decodeXmlText(List<int> bytes) {
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _safeFileStem(String input) {
    final cleaned = input
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? 'DecentSampler' : cleaned;
  }

  static String _normalizeZipPath(String path) {
    return p.posix.normalize(path.replaceAll('\\', '/')).replaceAll(RegExp(r'^/+'), '');
  }
}

class _DecentPresetPlan {
  const _DecentPresetPlan({
    required this.presetName,
    required this.regions,
    required this.sourceResolver,
  });

  final String presetName;
  final List<_DecentMappedRegion> regions;
  final _DecentSourceResolver sourceResolver;

  _DecentPresetPlan copyWith({_DecentSourceResolver? sourceResolver}) {
    return _DecentPresetPlan(
      presetName: presetName,
      regions: regions,
      sourceResolver: sourceResolver ?? this.sourceResolver,
    );
  }
}

class _DecentRawRegion {
  const _DecentRawRegion({
    required this.sourcePath,
    required this.rootMidi,
    required this.lowMidi,
    required this.highMidi,
    required this.velocityLow,
    required this.velocityHigh,
    required this.seqPosition,
    required this.loopStart,
    required this.loopEnd,
  });

  final String sourcePath;
  final int? rootMidi;
  final int? lowMidi;
  final int? highMidi;
  final int velocityLow;
  final int velocityHigh;
  final int? seqPosition;
  final int? loopStart;
  final int? loopEnd;
}

class _DecentMappedRegion {
  const _DecentMappedRegion({
    required this.sourcePath,
    required this.outputFileName,
    required this.rootMidi,
    required this.switchPoint,
    required this.velocityLayer,
    required this.roundRobin,
    required this.loopStart,
    required this.loopEnd,
  });

  final String sourcePath;
  final String outputFileName;
  final int rootMidi;
  final int switchPoint;
  final int velocityLayer;
  final int roundRobin;
  final int? loopStart;
  final int? loopEnd;
}

abstract class _DecentSourceResolver {
  const _DecentSourceResolver();

  Future<Uint8List?> read(String samplePath);
}

class _MissingDecentSourceResolver extends _DecentSourceResolver {
  const _MissingDecentSourceResolver();

  @override
  Future<Uint8List?> read(String samplePath) async => null;
}

class _LocalDecentSourceResolver extends _DecentSourceResolver {
  const _LocalDecentSourceResolver({required this.baseDirectory});

  final String baseDirectory;

  @override
  Future<Uint8List?> read(String samplePath) async {
    final file = File(p.normalize(p.join(baseDirectory, samplePath)));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }
}

class _ArchiveDecentSourceResolver extends _DecentSourceResolver {
  const _ArchiveDecentSourceResolver({
    required this.files,
    required this.presetDirectory,
  });

  final Map<String, ArchiveFile> files;
  final String presetDirectory;

  @override
  Future<Uint8List?> read(String samplePath) async {
    final path = DecentSamplerConverter._normalizeZipPath(
      p.posix.join(presetDirectory == '.' ? '' : presetDirectory, samplePath),
    );
    final file = files[path] ?? _caseInsensitiveLookup(path);
    if (file == null) return null;
    return Uint8List.fromList(file.content as List<int>);
  }

  ArchiveFile? _caseInsensitiveLookup(String path) {
    final lower = path.toLowerCase();
    for (final entry in files.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }
}
