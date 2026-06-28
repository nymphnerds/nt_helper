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
    required this.decisions,
    required this.warnings,
  });

  final List<String> outputFolders;
  final int copiedFiles;
  final List<String> decisions;
  final List<String> warnings;

  String get summary {
    final folderCount = outputFolders.length;
    final warningText = warnings.isEmpty
        ? 'No warnings.'
        : '${warnings.length} warning(s).';
    return 'Converted $copiedFiles WAV file(s) into $folderCount folder(s). $warningText';
  }
}

enum DecentSamplerGroupHandling {
  auto,
  velocityLayers,
  splitFolders,
  selectedGroup,
}

class DecentSamplerConvertOptions {
  const DecentSamplerConvertOptions({
    this.groupHandling = DecentSamplerGroupHandling.auto,
    this.selectedGroupKey,
  });

  final DecentSamplerGroupHandling groupHandling;
  final String? selectedGroupKey;
}

class DecentSamplerGroupInfo {
  const DecentSamplerGroupInfo({
    required this.key,
    required this.name,
    required this.xmlSummary,
    required this.sampleCount,
    required this.rootCount,
    required this.noteRange,
    required this.velocitySummary,
    required this.roundRobinSummary,
    required this.examples,
  });

  final String key;
  final String name;
  final String xmlSummary;
  final int sampleCount;
  final int rootCount;
  final String noteRange;
  final String velocitySummary;
  final String roundRobinSummary;
  final List<String> examples;

  DecentSamplerGroupInfo withDisplayName(String displayName) {
    return DecentSamplerGroupInfo(
      key: key,
      name: displayName,
      xmlSummary: xmlSummary,
      sampleCount: sampleCount,
      rootCount: rootCount,
      noteRange: noteRange,
      velocitySummary: velocitySummary,
      roundRobinSummary: roundRobinSummary,
      examples: examples,
    );
  }
}

class DecentSamplerImportAnalysis {
  const DecentSamplerImportAnalysis({
    required this.presetName,
    required this.groups,
    required this.hasAmbiguousOverlaps,
    required this.structureSummary,
    required this.recommendedGroupHandling,
  });

  final String presetName;
  final List<DecentSamplerGroupInfo> groups;
  final bool hasAmbiguousOverlaps;
  final String structureSummary;
  final DecentSamplerGroupHandling recommendedGroupHandling;
}

class DecentSamplerConverter {
  static const _supportedInputExtensions = {'.dspreset', '.dslibrary', '.zip'};

  Future<DecentSamplerConversionResult> convert({
    required String sourcePath,
    required String outputParentPath,
    DecentSamplerConvertOptions options = const DecentSamplerConvertOptions(),
  }) async {
    final extension = p.extension(sourcePath).toLowerCase();
    final sourceDirectory = Directory(sourcePath);
    final isDirectory = await sourceDirectory.exists();
    if (!isDirectory && !_supportedInputExtensions.contains(extension)) {
      throw FormatException('Unsupported Decent source: $extension');
    }

    final sourceFile = File(sourcePath);
    final sourceName = isDirectory
        ? p.basename(sourcePath)
        : p.basenameWithoutExtension(sourcePath);
    final decisions = <String>[];
    final warnings = <String>[];
    final plans = isDirectory
        ? await _readDirectory(
            sourceDirectory,
            sourceName,
            decisions,
            warnings,
            options,
          )
        : extension == '.dspreset'
        ? await _readDspreset(
            sourceFile,
            sourceName,
            decisions,
            warnings,
            options,
          )
        : await _readArchive(
            sourceFile,
            sourceName,
            decisions,
            warnings,
            options,
          );

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
      await _writeReport(plan, outputFolder, decisions, warnings);
    }

    return DecentSamplerConversionResult(
      outputFolders: outputFolders,
      copiedFiles: copiedFiles,
      decisions: decisions,
      warnings: warnings,
    );
  }

  Future<DecentSamplerImportAnalysis> analyze({
    required String sourcePath,
  }) async {
    final extension = p.extension(sourcePath).toLowerCase();
    final sourceDirectory = Directory(sourcePath);
    final isDirectory = await sourceDirectory.exists();
    if (!isDirectory && !_supportedInputExtensions.contains(extension)) {
      throw FormatException('Unsupported Decent source: $extension');
    }

    final sourceFile = File(sourcePath);
    final sourceName = isDirectory
        ? p.basename(sourcePath)
        : p.basenameWithoutExtension(sourcePath);
    final presetAnalyses = isDirectory
        ? await _analyzeDirectoryPresets(sourceDirectory, sourceName)
        : extension == '.dspreset'
        ? [
            _analyzePresetContent(
              _safeFileStem(sourceName),
              _fixInvalidXml(_decodeXmlText(await sourceFile.readAsBytes())),
            ),
          ]
        : await _analyzeArchivePresets(sourceFile, sourceName);
    final groups = <DecentSamplerGroupInfo>[];
    var hasAmbiguousOverlaps = false;
    final showPresetNames = presetAnalyses.length > 1;
    final summaries = <String>[];
    final recommendations = <DecentSamplerGroupHandling>{};
    for (final analysis in presetAnalyses) {
      hasAmbiguousOverlaps =
          hasAmbiguousOverlaps || analysis.hasAmbiguousOverlaps;
      recommendations.add(analysis.recommendedGroupHandling);
      if (analysis.structureSummary.isNotEmpty) {
        summaries.add(
          showPresetNames
              ? '${analysis.presetName}: ${analysis.structureSummary}'
              : analysis.structureSummary,
        );
      }
      groups.addAll(
        analysis.groups.map(
          (group) => showPresetNames
              ? group.withDisplayName('${analysis.presetName} / ${group.name}')
              : group,
        ),
      );
    }
    return DecentSamplerImportAnalysis(
      presetName: _safeFileStem(sourceName),
      groups: groups,
      hasAmbiguousOverlaps: hasAmbiguousOverlaps,
      structureSummary: summaries.join('\n'),
      recommendedGroupHandling: _mergeRecommendations(recommendations),
    );
  }

  Future<List<DecentSamplerImportAnalysis>> _analyzeDirectoryPresets(
    Directory directory,
    String fallbackName,
  ) async {
    final presetFiles = await _presetFilesInDirectory(directory);
    if (presetFiles.isEmpty) {
      throw const FormatException('No Decent Sampler preset found.');
    }
    return [
      for (final file in presetFiles)
        _analyzePresetContent(
          p.basenameWithoutExtension(file.path).isEmpty
              ? _safeFileStem(fallbackName)
              : _safeFileStem(p.basenameWithoutExtension(file.path)),
          _fixInvalidXml(_decodeXmlText(await file.readAsBytes())),
        ),
    ];
  }

  Future<List<DecentSamplerImportAnalysis>> _analyzeArchivePresets(
    File file,
    String fallbackName,
  ) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    final presetFiles =
        archive
            .where(
              (entry) =>
                  entry.isFile &&
                  !_isMacOsJunkPath(entry.name) &&
                  entry.name.toLowerCase().endsWith('.dspreset'),
            )
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    if (presetFiles.isEmpty) {
      throw const FormatException('No Decent Sampler preset found.');
    }
    return [
      for (final entry in presetFiles)
        _analyzePresetContent(
          p.posix.basenameWithoutExtension(entry.name).isEmpty
              ? _safeFileStem(fallbackName)
              : _safeFileStem(p.posix.basenameWithoutExtension(entry.name)),
          _fixInvalidXml(_decodeXmlText(entry.content as List<int>)),
        ),
    ];
  }

  DecentSamplerImportAnalysis _analyzePresetContent(
    String presetName,
    String content,
  ) {
    final groups = _sampleGroups(content);
    final warnings = <String>[];
    final rawRegions = _rawRegionsFromGroups(groups, presetName, warnings);
    final structureParts = [
      _structureSummary(groups, rawRegions, content),
      _uiGroupBindingSummary(content),
    ].where((part) => part.isNotEmpty).toList();
    return DecentSamplerImportAnalysis(
      presetName: presetName,
      groups: [for (final group in groups) _groupInfoFor(group, rawRegions)],
      hasAmbiguousOverlaps: _hasAmbiguousGroupOverlaps(rawRegions),
      structureSummary: structureParts.join('; '),
      recommendedGroupHandling: _recommendedGroupHandling(rawRegions),
    );
  }

  Future<List<_DecentPresetPlan>> _readDirectory(
    Directory directory,
    String fallbackName,
    List<String> decisions,
    List<String> warnings,
    DecentSamplerConvertOptions options,
  ) async {
    final presetFiles = await _presetFilesInDirectory(directory);
    if (presetFiles.isEmpty) {
      warnings.add('${directory.path} contains no .dspreset file.');
      return const [];
    }

    final plans = <_DecentPresetPlan>[];
    for (final file in presetFiles) {
      final presetName = p.basenameWithoutExtension(file.path);
      final presets = _parsePresetXml(
        _fixInvalidXml(_decodeXmlText(await file.readAsBytes())),
        presetName: presetName.isEmpty ? fallbackName : presetName,
        decisions: decisions,
        warnings: warnings,
        options: options,
      );
      plans.addAll(
        presets.map(
          (preset) => preset.copyWith(
            sourceResolver: _LocalDecentSourceResolver(
              baseDirectory: file.parent.path,
            ),
          ),
        ),
      );
    }
    return plans;
  }

  Future<List<_DecentPresetPlan>> _readDspreset(
    File file,
    String fallbackName,
    List<String> decisions,
    List<String> warnings,
    DecentSamplerConvertOptions options,
  ) async {
    final content = _fixInvalidXml(_decodeXmlText(await file.readAsBytes()));
    final presets = _parsePresetXml(
      content,
      presetName: fallbackName,
      decisions: decisions,
      warnings: warnings,
      options: options,
    );
    final baseDir = file.parent.path;
    return [
      for (final preset in presets)
        preset.copyWith(
          sourceResolver: _LocalDecentSourceResolver(baseDirectory: baseDir),
        ),
    ];
  }

  Future<List<_DecentPresetPlan>> _readArchive(
    File file,
    String fallbackName,
    List<String> decisions,
    List<String> warnings,
    DecentSamplerConvertOptions options,
  ) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    final files = archive
        .where((entry) => entry.isFile && !_isMacOsJunkPath(entry.name))
        .toList();
    final presetFiles =
        files
            .where((entry) => entry.name.toLowerCase().endsWith('.dspreset'))
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );

    if (presetFiles.isEmpty) {
      warnings.add('${p.basename(file.path)} contains no .dspreset file.');
      return const [];
    }

    final archiveFiles = {
      for (final entry in files) _normalizeZipPath(entry.name): entry,
    };
    final plans = <_DecentPresetPlan>[];
    for (final entry in presetFiles) {
      final content = _fixInvalidXml(
        _decodeXmlText(entry.content as List<int>),
      );
      final presetName = p.posix.basenameWithoutExtension(entry.name);
      final presets = _parsePresetXml(
        content,
        presetName: presetName.isEmpty ? fallbackName : presetName,
        decisions: decisions,
        warnings: warnings,
        options: options,
      );
      plans.addAll(
        presets.map(
          (preset) => preset.copyWith(
            sourceResolver: _ArchiveDecentSourceResolver(
              files: archiveFiles,
              presetDirectory: p.posix.dirname(_normalizeZipPath(entry.name)),
            ),
          ),
        ),
      );
    }
    return plans;
  }

  Future<List<File>> _presetFilesInDirectory(Directory directory) async {
    final files = <File>[];
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final normalized = entity.path.replaceAll('\\', '/');
      if (_isMacOsJunkPath(normalized)) continue;
      if (!entity.path.toLowerCase().endsWith('.dspreset')) continue;
      files.add(entity);
    }
    files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return files;
  }

  List<_DecentPresetPlan> _parsePresetXml(
    String content, {
    required String presetName,
    required List<String> decisions,
    required List<String> warnings,
    required DecentSamplerConvertOptions options,
  }) {
    final sampleGroups = _sampleGroups(content);
    if (sampleGroups.isEmpty) {
      warnings.add('$presetName has no <sample> entries.');
    }

    final rawRegions = _rawRegionsFromGroups(
      sampleGroups,
      presetName,
      warnings,
    );
    if (options.groupHandling == DecentSamplerGroupHandling.splitFolders) {
      final plans = <_DecentPresetPlan>[];
      final splitGroups = _splitFolderGroups(rawRegions);
      for (final splitGroup in splitGroups) {
        decisions.add(
          '$presetName: split `${splitGroup.label}` into its own output folder.',
        );
        plans.add(
          _DecentPresetPlan(
            presetName: _safeFileStem('${presetName}_${splitGroup.label}'),
            regions: _mapRawRegions(
              splitGroup.regions,
              '${presetName}_${splitGroup.label}',
              decisions,
              warnings,
              const DecentSamplerConvertOptions(),
            ),
            sourceResolver: const _MissingDecentSourceResolver(),
          ),
        );
      }
      return plans;
    }

    var regionsToMap = rawRegions;
    if (options.groupHandling == DecentSamplerGroupHandling.selectedGroup) {
      final selectedKey = options.selectedGroupKey;
      regionsToMap = rawRegions
          .where((region) => _groupKey(region) == selectedKey)
          .toList();
      final selectedName = _groupNameForKey(sampleGroups, selectedKey);
      decisions.add(
        '$presetName: converted selected group `${selectedName ?? selectedKey ?? 'unknown'}` only.',
      );
    }

    return [
      _DecentPresetPlan(
        presetName: _safeFileStem(presetName),
        regions: _mapRawRegions(
          regionsToMap,
          presetName,
          decisions,
          warnings,
          options,
        ),
        sourceResolver: const _MissingDecentSourceResolver(),
      ),
    ];
  }

  List<_DecentMappedRegion> _mapRawRegions(
    List<_DecentRawRegion> rawRegions,
    String presetName,
    List<String> decisions,
    List<String> warnings,
    DecentSamplerConvertOptions options,
  ) {
    final groupVelocityLayers =
        options.groupHandling == DecentSamplerGroupHandling.velocityLayers
        ? _forcedGroupVelocityLayers(rawRegions)
        : _dynamicGroupVelocityLayers(rawRegions);
    if (groupVelocityLayers != null) {
      if (options.groupHandling == DecentSamplerGroupHandling.velocityLayers) {
        decisions.add(
          '$presetName: user-selected velocity layers for Decent groups '
          '(${_groupLayerSummary(groupVelocityLayers)}).',
        );
      } else {
        decisions.add(
          '$presetName: auto-selected velocity layers for overlapping dynamic '
          'groups (${_groupLayerSummary(groupVelocityLayers)}).',
        );
      }
    } else {
      _warnAboutAmbiguousGroupOverlaps(
        rawRegions,
        presetName,
        decisions,
        warnings,
      );
    }

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
    if (groupVelocityLayers != null) {
      for (final region in rawRegions) {
        velocityLayerByRegion[region] =
            groupVelocityLayers[_groupKey(region)] ?? 1;
      }
    } else {
      for (final group in velocityKeys.values) {
        final hasExplicitVelocity = group.any(
          (region) => region.hasExplicitVelocity,
        );
        final ranges = hasExplicitVelocity
            ? (group
                  .map(
                    (region) => '${region.velocityLow}-${region.velocityHigh}',
                  )
                  .toSet()
                  .toList()
                ..sort((a, b) {
                  final aLow = int.tryParse(a.split('-').first) ?? 1;
                  final bLow = int.tryParse(b.split('-').first) ?? 1;
                  return aLow.compareTo(bLow);
                }))
            : <String>['1-127'];
        for (final region in group) {
          final key = '${region.velocityLow}-${region.velocityHigh}';
          velocityLayerByRegion[region] = hasExplicitVelocity
              ? ranges.indexOf(key) + 1
              : 1;
        }
      }
    }

    final usedRoundRobins = <String, Set<int>>{};
    final outputNames = <String>{};
    final mapped = <_DecentMappedRegion>[];
    var repairedRoundRobinCount = 0;
    final repairedRoundRobinExamples = <String>[];
    for (final region in rawRegions) {
      final root = region.rootMidi;
      if (root == null) continue;
      final low = (region.lowMidi ?? root).clamp(0, 127).toInt();
      final velocityLayer = velocityLayerByRegion[region] ?? 1;
      final velocityLayerCount =
          velocityKeys['$root|$low|${region.highMidi ?? -1}']
              ?.map((candidate) => velocityLayerByRegion[candidate] ?? 1)
              .toSet()
              .length ??
          1;
      final rrKey = '$root|$low|$velocityLayer';
      final roundRobin = _roundRobinForRegion(
        key: rrKey,
        requested: region.seqPosition,
        sourcePath: region.sourcePath,
        usedRoundRobins: usedRoundRobins,
        onDuplicateRequest: (sourcePath, requested, assigned) {
          repairedRoundRobinCount++;
          if (repairedRoundRobinExamples.length < 4) {
            repairedRoundRobinExamples.add(
              '${p.basename(sourcePath)} RR$requested->RR$assigned',
            );
          }
        },
      );
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
      );
      if (!outputNames.add(fileName.toLowerCase())) {
        warnings.add(
          '$presetName: skipped duplicate target mapping `$fileName` from '
          '${p.basename(region.sourcePath)}.',
        );
        continue;
      }
      mapped.add(
        _DecentMappedRegion(
          sourcePath: region.sourcePath,
          outputFileName: fileName,
          groupName: region.groupName,
          rootMidi: root,
          switchPoint: low,
          velocityLayer: velocityLayer,
          roundRobin: roundRobin,
          loopStart: region.loopStart,
          loopEnd: region.loopEnd,
        ),
      );
    }
    if (repairedRoundRobinCount > 0) {
      final suffix = repairedRoundRobinCount > repairedRoundRobinExamples.length
          ? ', ...'
          : '';
      decisions.add(
        '$presetName: repaired $repairedRoundRobinCount duplicate Decent '
        'round-robin request(s) by assigning the next free RR slot '
        '(${repairedRoundRobinExamples.join(', ')}$suffix).',
      );
    }
    return mapped;
  }

  static List<_DecentRawRegion> _rawRegionsFromGroups(
    List<_DecentSampleGroup> sampleGroups,
    String presetName,
    List<String> warnings,
  ) {
    final rawRegions = <_DecentRawRegion>[];
    for (final group in sampleGroups) {
      final groupSeqPosition = _parseIntAttribute(
        group.attributes['seqposition'],
      );
      final groupHasExplicitVelocity =
          group.attributes.containsKey('lovel') ||
          group.attributes.containsKey('hivel');
      final groupVelocityLow = _parseIntAttribute(group.attributes['lovel']);
      final groupVelocityHigh = _parseIntAttribute(group.attributes['hivel']);
      for (final sample in group.samples) {
        final samplePath = sample['path'];
        if (samplePath == null || samplePath.trim().isEmpty) {
          warnings.add('$presetName has a sample with no path.');
          continue;
        }
        final rootMidi = _parseNoteAttribute(sample['rootnote']);
        final lowMidi = _parseNoteAttribute(sample['lonote']);
        final highMidi = _parseNoteAttribute(sample['hinote']);
        final hasExplicitVelocity =
            sample.containsKey('lovel') ||
            sample.containsKey('hivel') ||
            groupHasExplicitVelocity;
        final velocityLow =
            _parseIntAttribute(sample['lovel']) ?? groupVelocityLow ?? 1;
        final velocityHigh =
            _parseIntAttribute(sample['hivel']) ?? groupVelocityHigh ?? 127;
        final seqPosition =
            _parseIntAttribute(sample['seqposition']) ?? groupSeqPosition;
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
            hasExplicitVelocity: hasExplicitVelocity,
            seqPosition: seqPosition,
            loopStart: loopStart,
            loopEnd: loopEnd,
            groupName: group.name,
            groupIndex: group.index,
          ),
        );
      }
    }
    return rawRegions;
  }

  static DecentSamplerGroupInfo _groupInfoFor(
    _DecentSampleGroup group,
    List<_DecentRawRegion> rawRegions,
  ) {
    final key = _groupKeyFromParts(group.index, group.name);
    final groupRegions = rawRegions
        .where((region) => _groupKey(region) == key)
        .toList();
    final roots =
        groupRegions
            .map((region) => region.rootMidi)
            .whereType<int>()
            .toSet()
            .toList()
          ..sort();
    final lows = groupRegions
        .map((region) => region.lowMidi ?? region.rootMidi)
        .whereType<int>();
    final highs = groupRegions
        .map((region) => region.highMidi ?? region.rootMidi)
        .whereType<int>();
    final notes = [...lows, ...highs].toList()..sort();
    final velocityRanges =
        groupRegions
            .where((region) => region.hasExplicitVelocity)
            .map((region) => '${region.velocityLow}-${region.velocityHigh}')
            .toSet()
            .toList()
          ..sort((a, b) {
            final aLow = int.tryParse(a.split('-').first) ?? 1;
            final bLow = int.tryParse(b.split('-').first) ?? 1;
            return aLow.compareTo(bLow);
          });
    final rrValues =
        groupRegions
            .map((region) => region.seqPosition)
            .whereType<int>()
            .toSet()
            .toList()
          ..sort();
    final examples =
        groupRegions
            .map((region) => p.basename(region.sourcePath))
            .toSet()
            .toList()
          ..sort();
    return DecentSamplerGroupInfo(
      key: key,
      name: group.name,
      xmlSummary: _groupXmlSummary(group),
      sampleCount: group.samples.length,
      rootCount: roots.length,
      noteRange: notes.isEmpty
          ? 'No notes'
          : '${PolyMultisampleParser.midiToNoteName(notes.first)} - ${PolyMultisampleParser.midiToNoteName(notes.last)}',
      velocitySummary: velocityRanges.isEmpty
          ? 'No explicit velocity ranges'
          : velocityRanges.join(', '),
      roundRobinSummary: rrValues.isEmpty
          ? 'No seqPosition'
          : 'RR ${rrValues.first}-${rrValues.last}',
      examples: examples.take(4).toList(),
    );
  }

  Map<String, int>? _dynamicGroupVelocityLayers(
    List<_DecentRawRegion> rawRegions,
  ) {
    if (rawRegions.any((region) => region.hasExplicitVelocity)) return null;
    final structuralRoundRobinLayers = _structuralRoundRobinBankVelocityLayers(
      rawRegions,
      requireDynamicNames: true,
    );
    if (structuralRoundRobinLayers != null) {
      return structuralRoundRobinLayers;
    }

    final groupKeys = <String>{
      for (final region in rawRegions) _groupKey(region),
    };
    if (groupKeys.length < 2) return null;
    if (!groupKeys.every(_isDynamicGroupName)) return null;

    final signatures = <String, Set<String>>{};
    for (final region in rawRegions) {
      signatures
          .putIfAbsent(_groupKey(region), () => <String>{})
          .add(_mappingSignature(region));
    }
    if (signatures.length < 2) return null;
    final first = signatures.values.first;
    if (!signatures.values.every((signature) => _sameSet(signature, first))) {
      return null;
    }

    final sorted = groupKeys.toList()
      ..sort((a, b) {
        final rank = _dynamicGroupRank(a).compareTo(_dynamicGroupRank(b));
        return rank != 0 ? rank : a.compareTo(b);
      });
    return {
      for (var index = 0; index < sorted.length; index++)
        sorted[index]: index + 1,
    };
  }

  Map<String, int>? _forcedGroupVelocityLayers(
    List<_DecentRawRegion> rawRegions,
  ) {
    final structuralRoundRobinLayers = _structuralRoundRobinBankVelocityLayers(
      rawRegions,
      requireDynamicNames: false,
    );
    if (structuralRoundRobinLayers != null) {
      return structuralRoundRobinLayers;
    }
    if (rawRegions.any((region) => region.seqPosition != null) &&
        _roundRobinBankLabels(rawRegions).isEmpty) {
      return null;
    }

    final groupKeys =
        <String>{for (final region in rawRegions) _groupKey(region)}.toList()
          ..sort((a, b) {
            final aIndex = int.tryParse(a.split(':').first) ?? 0;
            final bIndex = int.tryParse(b.split(':').first) ?? 0;
            return aIndex.compareTo(bIndex);
          });
    if (groupKeys.length < 2) return null;
    return {
      for (var index = 0; index < groupKeys.length; index++)
        groupKeys[index]: index + 1,
    };
  }

  static List<_SplitFolderGroup> _splitFolderGroups(
    List<_DecentRawRegion> rawRegions,
  ) {
    final groups = <String, _MutableSplitFolderGroup>{};
    for (final region in rawRegions) {
      final hasRoundRobinAxis = region.seqPosition != null;
      final label = hasRoundRobinAxis
          ? _roundRobinBankLabel(region)
          : region.groupName;
      final key = hasRoundRobinAxis
          ? (label.isEmpty ? 'round-robin-set' : _labelKey(label))
          : _groupKey(region);
      final group = groups.putIfAbsent(
        key,
        () => _MutableSplitFolderGroup(
          label: label.isEmpty ? 'Round robin set' : label,
          firstGroupIndex: region.groupIndex,
        ),
      );
      if (region.groupIndex < group.firstGroupIndex) {
        group.firstGroupIndex = region.groupIndex;
      }
      group.regions.add(region);
    }
    final result =
        groups.values
            .map(
              (group) => _SplitFolderGroup(
                label: group.label,
                firstGroupIndex: group.firstGroupIndex,
                regions: group.regions,
              ),
            )
            .toList()
          ..sort((a, b) => a.firstGroupIndex.compareTo(b.firstGroupIndex));
    return result;
  }

  static Map<String, int>? _structuralRoundRobinBankVelocityLayers(
    List<_DecentRawRegion> rawRegions, {
    required bool requireDynamicNames,
  }) {
    if (!rawRegions.any((region) => region.seqPosition != null)) return null;

    final bankLabels = <String, String>{};
    final bankSignatures = <String, Set<String>>{};
    final bankGroupKeys = <String, Set<String>>{};
    for (final region in rawRegions) {
      final label = _roundRobinBankLabel(region);
      if (label.isEmpty) return null;
      final bankKey = _labelKey(label);
      bankLabels[bankKey] = label;
      bankSignatures
          .putIfAbsent(bankKey, () => <String>{})
          .add(_mappingSignature(region));
      bankGroupKeys
          .putIfAbsent(bankKey, () => <String>{})
          .add(_groupKey(region));
    }
    if (bankLabels.length < 2) return null;
    if (requireDynamicNames &&
        !bankLabels.values.every((label) => _isDynamicLabel(label))) {
      return null;
    }

    final firstSignature = bankSignatures.values.first;
    if (!bankSignatures.values.every(
      (signature) => _sameSet(signature, firstSignature),
    )) {
      return null;
    }

    final sortedBankKeys = bankLabels.keys.toList()
      ..sort((a, b) {
        final rank = _dynamicLabelRank(
          bankLabels[a]!,
        ).compareTo(_dynamicLabelRank(bankLabels[b]!));
        return rank != 0 ? rank : bankLabels[a]!.compareTo(bankLabels[b]!);
      });
    final layers = <String, int>{};
    for (var index = 0; index < sortedBankKeys.length; index++) {
      final bankKey = sortedBankKeys[index];
      for (final groupKey in bankGroupKeys[bankKey]!) {
        layers[groupKey] = index + 1;
      }
    }
    return layers;
  }

  static bool _hasAmbiguousGroupOverlaps(List<_DecentRawRegion> rawRegions) {
    if (!rawRegions.any((region) => region.hasExplicitVelocity) &&
        _dynamicGroupVelocityLayersStatic(rawRegions) != null) {
      return false;
    }
    final signatures = <String, Set<String>>{};
    for (final region in rawRegions) {
      signatures
          .putIfAbsent(_overlapSignature(region), () => <String>{})
          .add(_groupKey(region));
    }
    return signatures.values.any((groups) => groups.length > 1);
  }

  static Map<String, int>? _dynamicGroupVelocityLayersStatic(
    List<_DecentRawRegion> rawRegions,
  ) {
    if (rawRegions.any((region) => region.hasExplicitVelocity)) return null;
    final groupKeys = <String>{
      for (final region in rawRegions) _groupKey(region),
    };
    if (groupKeys.length < 2) return null;
    if (!groupKeys.every(_isDynamicGroupName)) return null;

    final signatures = <String, Set<String>>{};
    for (final region in rawRegions) {
      signatures
          .putIfAbsent(_groupKey(region), () => <String>{})
          .add(_mappingSignature(region));
    }
    if (signatures.length < 2) return null;
    final first = signatures.values.first;
    if (!signatures.values.every((signature) => _sameSet(signature, first))) {
      return null;
    }

    final sorted = groupKeys.toList()
      ..sort((a, b) {
        final rank = _dynamicGroupRank(a).compareTo(_dynamicGroupRank(b));
        return rank != 0 ? rank : a.compareTo(b);
      });
    return {
      for (var index = 0; index < sorted.length; index++)
        sorted[index]: index + 1,
    };
  }

  void _warnAboutAmbiguousGroupOverlaps(
    List<_DecentRawRegion> rawRegions,
    String presetName,
    List<String> decisions,
    List<String> warnings,
  ) {
    final signatures = <String, Set<String>>{};
    for (final region in rawRegions) {
      signatures
          .putIfAbsent(_overlapSignature(region), () => <String>{})
          .add(_groupKey(region));
    }
    final overlappingGroups =
        signatures.values
            .where((groups) => groups.length > 1)
            .expand((groups) => groups)
            .toSet()
            .toList()
          ..sort();
    if (overlappingGroups.isEmpty) return;
    warnings.add(
      '$presetName: overlapping Decent groups were not auto-merged '
      '(${overlappingGroups.take(8).join(', ')}). Choose velocity, folder, '
      'or selected-group handling if this needs a different interpretation.',
    );
    decisions.add(
      '$presetName: suggested choices for overlapping groups: use velocity '
      'layers if these are dynamics, split to separate folders if these are '
      'articulations/mics, or convert only the intended group if one group is '
      'controlled by a macro/modwheel.',
    );
  }

  int _roundRobinForRegion({
    required String key,
    required int? requested,
    required String sourcePath,
    required Map<String, Set<int>> usedRoundRobins,
    required void Function(String sourcePath, int requested, int assigned)
    onDuplicateRequest,
  }) {
    final used = usedRoundRobins.putIfAbsent(key, () => <int>{});
    if (requested != null && requested > 0 && !used.contains(requested)) {
      used.add(requested);
      return requested;
    }

    var next = 1;
    while (used.contains(next)) {
      next++;
    }
    used.add(next);
    if (requested != null && requested > 0) {
      onDuplicateRequest(sourcePath, requested, next);
    }
    return next;
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
      await outputFile.writeAsBytes(outputBytes);
      copied++;
    }
    return copied;
  }

  Future<void> _writeReport(
    _DecentPresetPlan plan,
    Directory outputFolder,
    List<String> decisions,
    List<String> warnings,
  ) async {
    final lines = <String>[
      '# Decent Sampler Conversion Report',
      '',
      '- Preset: `${plan.presetName}`',
      '- Output folder: `${outputFolder.path}`',
      '- Regions planned: ${plan.regions.length}',
      '',
      '## Conversion decisions',
      '',
      if (decisions.isEmpty)
        '- Auto/default mapping only.'
      else
        for (final decision in decisions) '- $decision',
      '',
      '## Files',
      '',
      '| Group | Source | Output | Root | Switch | Velocity | Round robin | Loop |',
      '| --- | --- | --- | --- | --- | --- | --- | --- |',
      for (final region in plan.regions)
        '| `${region.groupName}` | `${region.sourcePath}` | `${region.outputFileName}` | ${PolyMultisampleParser.midiToNoteName(region.rootMidi)} | ${region.switchPoint} | V${region.velocityLayer} | RR${region.roundRobin} | ${region.loopStart != null && region.loopEnd != null ? '${region.loopStart}-${region.loopEnd}' : '-'} |',
      '',
      '## Warnings',
      '',
      if (warnings.isEmpty)
        '- None'
      else
        for (final warning in warnings) '- $warning',
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
    return '${parts.join('_')}.wav';
  }

  static List<_DecentSampleGroup> _sampleGroups(String content) {
    final document = html_parser.parse(content);
    final root = document.querySelector('decentsampler');
    final groupElements =
        root?.querySelectorAll('groups group') ?? const <html_dom.Element>[];
    if (groupElements.isNotEmpty) {
      return [
        for (var index = 0; index < groupElements.length; index++)
          _DecentSampleGroup(
            index: index,
            attributes: _elementAttributes(groupElements[index]),
            samples: groupElements[index]
                .querySelectorAll('sample')
                .map(_elementAttributes)
                .toList(),
          ),
      ].where((group) => group.samples.isNotEmpty).toList();
    }
    final looseSamples =
        root?.querySelectorAll('sample') ?? const <html_dom.Element>[];
    if (looseSamples.isNotEmpty) {
      return [
        _DecentSampleGroup(
          index: 0,
          attributes: const {'name': 'Ungrouped'},
          samples: looseSamples.map(_elementAttributes).toList(),
        ),
      ];
    }
    return _sampleGroupsFromText(content);
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

  static List<_DecentSampleGroup> _sampleGroupsFromText(String content) {
    final groups = <_DecentSampleGroup>[];
    final groupPattern = RegExp(
      r'<\s*group\b([^>]*)>(.*?)<\s*/\s*group\s*>',
      caseSensitive: false,
      dotAll: true,
      multiLine: true,
    );
    var index = 0;
    for (final match in groupPattern.allMatches(content)) {
      final attrs = _tagAttributes(match.group(1) ?? '');
      final body = match.group(2) ?? '';
      final samples = _sampleTagsFromText(body).map(_tagAttributes).toList();
      if (samples.isEmpty) continue;
      groups.add(
        _DecentSampleGroup(index: index++, attributes: attrs, samples: samples),
      );
    }
    if (groups.isNotEmpty) return groups;
    final samples = _sampleTagsFromText(content).map(_tagAttributes).toList();
    if (samples.isEmpty) return const [];
    return [
      _DecentSampleGroup(
        index: 0,
        attributes: const {'name': 'Ungrouped'},
        samples: samples,
      ),
    ];
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
    return int.tryParse(trimmed) ??
        PolyMultisampleParser.noteNameToMidi(trimmed);
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
    return p.posix
        .normalize(path.replaceAll('\\', '/'))
        .replaceAll(RegExp(r'^/+'), '');
  }

  static bool _isMacOsJunkPath(String path) {
    final normalized = _normalizeZipPath(path);
    if (normalized.isEmpty) return true;
    final parts = normalized.split('/');
    return parts.any(
      (part) =>
          part == '__MACOSX' || part == '.DS_Store' || part.startsWith('._'),
    );
  }

  static String _groupKey(_DecentRawRegion region) {
    return _groupKeyFromParts(region.groupIndex, region.groupName);
  }

  static String _groupKeyFromParts(int index, String name) {
    return '$index:$name';
  }

  static String _groupXmlSummary(_DecentSampleGroup group) {
    final attrs = Map<String, String>.of(group.attributes)
      ..removeWhere((key, value) => key == 'name' || value.trim().isEmpty);
    if (attrs.isEmpty) return 'No group-level XML attributes';
    final priority = [
      'seqmode',
      'trigger',
      'lovel',
      'hivel',
      'lokey',
      'hikey',
      'volume',
      'pan',
      'tags',
      'silencedbytags',
      'silencingmode',
    ];
    final keys = [
      ...priority.where(attrs.containsKey),
      ...attrs.keys.where((key) => !priority.contains(key)).toList()..sort(),
    ];
    return keys.take(8).map((key) => '$key=${attrs[key]}').join(', ');
  }

  static String? _groupNameForKey(
    List<_DecentSampleGroup> groups,
    String? key,
  ) {
    if (key == null) return null;
    for (final group in groups) {
      if (_groupKeyFromParts(group.index, group.name) == key) {
        return group.name;
      }
    }
    return null;
  }

  static String _mappingSignature(_DecentRawRegion region) {
    final root = region.rootMidi ?? -1;
    final low = region.lowMidi ?? root;
    final high = region.highMidi ?? root;
    return '$root|$low|$high|${region.seqPosition ?? '-'}';
  }

  static String _overlapSignature(_DecentRawRegion region) {
    final root = region.rootMidi ?? -1;
    final low = region.lowMidi ?? root;
    final high = region.highMidi ?? root;
    final velocity = region.hasExplicitVelocity
        ? '${region.velocityLow}-${region.velocityHigh}'
        : '1-127';
    return '$root|$low|$high|$velocity|${region.seqPosition ?? '-'}';
  }

  static String _structureSummary(
    List<_DecentSampleGroup> sampleGroups,
    List<_DecentRawRegion> rawRegions,
    String content,
  ) {
    if (rawRegions.isEmpty) return '';
    final roots = rawRegions
        .map((region) => region.rootMidi)
        .whereType<int>()
        .toSet();
    final roundRobins =
        rawRegions.map((region) => region.seqPosition).whereType<int>().toList()
          ..sort();
    final explicitVelocityRanges =
        rawRegions
            .where((region) => region.hasExplicitVelocity)
            .map((region) => '${region.velocityLow}-${region.velocityHigh}')
            .toSet()
            .toList()
          ..sort();

    final layerToRoundRobins = <String, Set<int>>{};
    for (final region in rawRegions.where(
      (region) => region.seqPosition != null,
    )) {
      final label = _roundRobinBankLabel(region);
      if (label.isEmpty) continue;
      layerToRoundRobins
          .putIfAbsent(label, () => <int>{})
          .add(region.seqPosition!);
    }
    final bindings = _groupBindings(content);
    final bindingParams = bindings
        .map((binding) => binding.parameter)
        .where((value) => value.isNotEmpty)
        .toSet();
    final bindingControls = bindings
        .map((binding) => binding.controlLabel)
        .where((value) => value.isNotEmpty)
        .toSet();
    final groupLabels =
        sampleGroups
            .map((group) => _roundRobinBankLabelFromName(group.name, null))
            .where((label) => label.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

    final parts = <String>[];
    parts.add(
      '${sampleGroups.length} group(s), ${rawRegions.length} sample(s)',
    );

    if (layerToRoundRobins.length > 1 && roundRobins.isNotEmpty) {
      final layerNames = layerToRoundRobins.keys.toList()..sort();
      final rrValues = roundRobins.toSet().toList()..sort();
      final allLayersUseSameRr = layerToRoundRobins.values.every(
        (values) => _sameSet(
          values.map((value) => value.toString()).toSet(),
          rrValues.map((value) => value.toString()).toSet(),
        ),
      );
      parts.add(
        '${layerNames.length} labelled group layer(s) (${layerNames.take(6).join(', ')}) '
        '${allLayersUseSameRr ? 'each ' : ''}with RR ${rrValues.first}-${rrValues.last}',
      );
    } else if (groupLabels.length > 1) {
      parts.add('group labels ${groupLabels.take(8).join(', ')}');
    } else if (roundRobins.isNotEmpty) {
      final rrValues = roundRobins.toSet().toList()..sort();
      parts.add('round robins RR ${rrValues.first}-${rrValues.last}');
    }

    if (explicitVelocityRanges.isNotEmpty) {
      if (explicitVelocityRanges.length == 1 &&
          explicitVelocityRanges.first == '1-127') {
        parts.add('all samples use full velocity 1-127');
      } else {
        parts.add(
          '${explicitVelocityRanges.length} explicit velocity range(s): ${explicitVelocityRanges.take(8).join(', ')}',
        );
      }
    }
    if (bindingParams.isNotEmpty) {
      final controls = bindingControls.isEmpty
          ? 'Decent UI/control bindings'
          : 'Decent controls ${bindingControls.take(5).join(', ')}';
      final params = bindingParams.take(6).join(', ');
      final bindsVolume = bindingParams.any(
        (param) => param.toUpperCase().contains('VOLUME'),
      );
      final bindsEnabled = bindingParams.any(
        (param) => param.toUpperCase().contains('ENABLED'),
      );
      if (bindsVolume) {
        parts.add(
          '$controls fade/mix group volume ($params), so these may be controller layers rather than velocity layers',
        );
      } else if (bindsEnabled) {
        parts.add(
          '$controls switch groups on/off ($params), so these may be articulations/options',
        );
      } else {
        parts.add('$controls affect groups ($params)');
      }
    }
    parts.add('${roots.length} root note(s)');
    return parts.join('; ');
  }

  static String _uiGroupBindingSummary(String content) {
    final bindings = _groupBindings(content);
    if (bindings.isEmpty) return '';
    final positions = bindings
        .map((binding) => binding.position)
        .whereType<int>()
        .toSet();
    final params = bindings
        .map((binding) => binding.parameter)
        .where((value) => value.isNotEmpty)
        .toSet();
    final controls = bindings
        .map((binding) => binding.controlLabel)
        .where((value) => value.isNotEmpty)
        .toSet();
    if (positions.isEmpty) return '';
    final sortedPositions = positions.toList()..sort();
    final sortedParams = params.toList()..sort();
    final sortedControls = controls.toList()..sort();
    final controlText = sortedControls.isEmpty
        ? 'UI controls'
        : 'UI controls ${sortedControls.take(4).join(', ')}';
    final paramText = sortedParams.isEmpty
        ? ''
        : ' (${sortedParams.take(4).join(', ')})';
    final linksVolume = sortedParams.any(
      (param) => param.toUpperCase().contains('VOLUME'),
    );
    final action = linksVolume
        ? 'control group volume for positions'
        : 'bind group positions';
    return '$controlText $action ${sortedPositions.join(', ')}$paramText';
  }

  static List<_GroupBindingInfo> _groupBindings(String content) {
    final document = html_parser.parse(content);
    final root = document.querySelector('decentsampler');
    if (root == null) return const [];
    final bindings = <_GroupBindingInfo>[];
    for (final binding in root.querySelectorAll('binding')) {
      final attrs = _elementAttributes(binding);
      if (attrs['level']?.toLowerCase() != 'group') continue;
      final parent = binding.parent;
      final parentAttrs = parent == null
          ? const <String, String>{}
          : _elementAttributes(parent);
      bindings.add(
        _GroupBindingInfo(
          position: _parseIntAttribute(attrs['position']),
          parameter: attrs['parameter']?.trim() ?? '',
          controlLabel: (parentAttrs['label'] ?? parentAttrs['name'] ?? '')
              .trim(),
        ),
      );
    }
    return bindings;
  }

  static DecentSamplerGroupHandling _recommendedGroupHandling(
    List<_DecentRawRegion> rawRegions,
  ) {
    final banks = _roundRobinBankLabels(rawRegions);
    if (banks.length > 1) {
      final labels = banks.values.toList();
      return labels.every(_isDynamicLabel)
          ? DecentSamplerGroupHandling.velocityLayers
          : DecentSamplerGroupHandling.splitFolders;
    }
    if (_dynamicGroupVelocityLayersStatic(rawRegions) != null) {
      return DecentSamplerGroupHandling.velocityLayers;
    }
    return DecentSamplerGroupHandling.velocityLayers;
  }

  static DecentSamplerGroupHandling _mergeRecommendations(
    Set<DecentSamplerGroupHandling> recommendations,
  ) {
    if (recommendations.contains(DecentSamplerGroupHandling.splitFolders)) {
      return DecentSamplerGroupHandling.splitFolders;
    }
    if (recommendations.contains(DecentSamplerGroupHandling.velocityLayers)) {
      return DecentSamplerGroupHandling.velocityLayers;
    }
    return DecentSamplerGroupHandling.auto;
  }

  static Map<String, String> _roundRobinBankLabels(
    List<_DecentRawRegion> rawRegions,
  ) {
    final labels = <String, String>{};
    for (final region in rawRegions) {
      if (region.seqPosition == null) continue;
      final label = _roundRobinBankLabel(region);
      if (label.isEmpty) continue;
      labels[_labelKey(label)] = label;
    }
    return labels;
  }

  static String _roundRobinBankLabel(_DecentRawRegion region) {
    return _roundRobinBankLabelFromName(region.groupName, region.seqPosition);
  }

  static String _roundRobinBankLabelFromName(String name, int? rr) {
    var label = name.trim();
    if (rr != null) {
      for (final pattern in [
        RegExp(
          '(^|[\\s_\\-])rr\\s*0*$rr(?=\$|[\\s_\\-])',
          caseSensitive: false,
        ),
        RegExp(
          '(^|[\\s_\\-])round\\s*robin\\s*0*$rr(?=\$|[\\s_\\-])',
          caseSensitive: false,
        ),
        RegExp(
          '(^|[\\s_\\-])seq\\s*0*$rr(?=\$|[\\s_\\-])',
          caseSensitive: false,
        ),
      ]) {
        label = label.replaceAll(pattern, ' ');
      }
    }
    label = _compactLabel(label);
    if (label.isEmpty || _isGenericGroupLabel(label)) return '';
    return label;
  }

  static String _compactLabel(String value) {
    return value
        .replaceAll(RegExp(r'[\s_\-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool _isGenericGroupLabel(String label) {
    final normalized = _labelKey(label).replaceAll(RegExp(r'[^a-z0-9]+'), '');
    return normalized.isEmpty ||
        normalized == 'group' ||
        RegExp(r'^group\\d+$').hasMatch(normalized);
  }

  static String _labelKey(String value) => _compactLabel(value).toLowerCase();

  static bool _isDynamicLabel(String label) {
    return label
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.isNotEmpty)
        .any(
          (word) =>
              _dynamicNameRanks.containsKey(word) ||
              RegExp(r'^vel\d+$').hasMatch(word),
        );
  }

  static int _dynamicLabelRank(String label) {
    final words = label
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.isNotEmpty);
    var rank = 1000;
    for (final word in words) {
      final velMatch = RegExp(r'^vel(\d+)$').firstMatch(word);
      if (velMatch != null) {
        final value = int.parse(velMatch.group(1)!);
        if (value < rank) rank = value;
      }
      final value = _dynamicNameRanks[word];
      if (value != null && value < rank) rank = value;
    }
    return rank;
  }

  static bool _sameSet(Set<String> a, Set<String> b) {
    return a.length == b.length && a.containsAll(b);
  }

  static bool _isDynamicGroupName(String key) {
    final name = key.substring(key.indexOf(':') + 1).toLowerCase();
    final words = name
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.isNotEmpty);
    return words.any((word) {
      return _dynamicNameRanks.containsKey(word) ||
          RegExp(r'^vel\d+$').hasMatch(word);
    });
  }

  static int _dynamicGroupRank(String key) {
    final name = key.substring(key.indexOf(':') + 1).toLowerCase();
    final words = name
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.isNotEmpty);
    var rank = 1000;
    for (final word in words) {
      final velMatch = RegExp(r'^vel(\d+)$').firstMatch(word);
      if (velMatch != null) {
        rank = rank < int.parse(velMatch.group(1)!)
            ? rank
            : int.parse(velMatch.group(1)!);
      }
      final value = _dynamicNameRanks[word];
      if (value != null && value < rank) rank = value;
    }
    return rank;
  }

  static String _groupLayerSummary(Map<String, int> layers) {
    final entries = layers.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return entries
        .map(
          (entry) =>
              '${entry.key.substring(entry.key.indexOf(':') + 1)}=V${entry.value}',
        )
        .join(', ');
  }

  static const _dynamicNameRanks = {
    'pp': 1,
    'p': 2,
    'soft': 2,
    'quiet': 2,
    'low': 2,
    'mp': 3,
    'medium': 3,
    'med': 3,
    'mid': 3,
    'mf': 4,
    'hard': 5,
    'loud': 5,
    'high': 5,
    'f': 6,
    'ff': 7,
    'fff': 8,
  };
}

class _DecentSampleGroup {
  const _DecentSampleGroup({
    required this.index,
    required this.attributes,
    required this.samples,
  });

  final int index;
  final Map<String, String> attributes;
  final List<Map<String, String>> samples;

  String get name {
    final explicitName = attributes['name']?.trim();
    if (explicitName != null && explicitName.isNotEmpty) return explicitName;
    for (final key in const ['tags', 'tag', 'articulation', 'mic', 'label']) {
      final value = attributes[key]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return 'Group ${index + 1}';
  }
}

class _GroupBindingInfo {
  const _GroupBindingInfo({
    required this.position,
    required this.parameter,
    required this.controlLabel,
  });

  final int? position;
  final String parameter;
  final String controlLabel;
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

class _MutableSplitFolderGroup {
  _MutableSplitFolderGroup({
    required this.label,
    required this.firstGroupIndex,
  });

  final String label;
  int firstGroupIndex;
  final List<_DecentRawRegion> regions = [];
}

class _SplitFolderGroup {
  const _SplitFolderGroup({
    required this.label,
    required this.firstGroupIndex,
    required this.regions,
  });

  final String label;
  final int firstGroupIndex;
  final List<_DecentRawRegion> regions;
}

class _DecentRawRegion {
  const _DecentRawRegion({
    required this.sourcePath,
    required this.rootMidi,
    required this.lowMidi,
    required this.highMidi,
    required this.velocityLow,
    required this.velocityHigh,
    required this.hasExplicitVelocity,
    required this.seqPosition,
    required this.loopStart,
    required this.loopEnd,
    required this.groupName,
    required this.groupIndex,
  });

  final String sourcePath;
  final int? rootMidi;
  final int? lowMidi;
  final int? highMidi;
  final int velocityLow;
  final int velocityHigh;
  final bool hasExplicitVelocity;
  final int? seqPosition;
  final int? loopStart;
  final int? loopEnd;
  final String groupName;
  final int groupIndex;
}

class _DecentMappedRegion {
  const _DecentMappedRegion({
    required this.sourcePath,
    required this.outputFileName,
    required this.groupName,
    required this.rootMidi,
    required this.switchPoint,
    required this.velocityLayer,
    required this.roundRobin,
    required this.loopStart,
    required this.loopEnd,
  });

  final String sourcePath;
  final String outputFileName;
  final String groupName;
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
