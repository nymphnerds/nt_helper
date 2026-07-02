# Polysampler Builder Fork

This branch adds a `Samples` workspace for building and editing Disting NT Poly Multisample folders. The goal is a practical, staged workflow for making clean `/samples/<instrument>` folders from local WAVs, mounted SD folders, and Decent Sampler sources.

## Current Scope

- Opens existing local or mounted Disting-style sample folders.
- Opens direct NT SD sample folders for listing and filename/tag edits.
- Imports Decent Sampler sources: `.dslibrary`, `.zip`, `.dspreset`, and already extracted folders.
- Builds custom draft folders from loose WAVs, source folders, or selected Decent groups/files.
- Copies sources on save; originals are not modified by custom mode.
- Outputs WAV files only.
- Optionally copies likely license/readme/manual/info/artwork files into `_source_docs`.
- Lets users preview/audition candidate WAVs before adding them from loose-file selections or Decent Sampler sources.

Waveform display, audio preview, loop metadata edits, and destructive WAV edits are local/mounted-folder features only. Direct NT SD file browsing remains available, but direct WAV preview/download over MIDI/SysEx is intentionally disabled because full-file transfer is too slow and unreliable for this workflow.

## Import Logic

The Decent importer reads the preset XML before converting. It always reports the detected structure first, then lets the user choose the material and mapping for one Disting NT Poly Multisample folder.

The report tries to expose:

- number of groups and samples;
- labelled group/layer names from XML attributes such as `name`, `label`, `tags`, `articulation`, or `mic`;
- explicit velocity ranges;
- round-robin/`seqPosition` use;
- UI/controller bindings that suggest Decent-only controls such as volume fades, enabled switches, pan, or tuning.

Current flow:

- choose one preset first when a Decent library contains multiple presets;
- choose Tags or Groups where both expose useful structure;
- choose `Use Decent map`, `Chromatic`, `Velocity layers`, `Round robins`, or `Add unmapped`;
- preview tag/group rows before selecting them;
- edit selected rows with Disting-style `Low`, `Root`, `Vel`, and `RR` controls;
- use `Smart edits` for automatic conflict repair or `Manual edits` for complex mappings where overlaps are shown and `Continue` is blocked until fixed.

`Use Decent map` defaults to Manual edits and shows XML summaries such as root counts, velocity ranges, and RR slots until the user overrides a field. Other mapping modes default to Smart edits.

In Manual edits, rows never shift, reseed, swap, or prune automatically; overlaps are shown and `Continue` is disabled until fixed. In Chromatic, Velocity layers, Round robins, and Add unmapped, the converter exports the full visible row mapping instead of falling back to Decent XML for untouched axes.

The importer deliberately does not expose a `High` control. `Low` is the switch point/range-boundary control used by the Disting NT Poly Multisample workflow.

The importer ignores common macOS archive junk such as `__MACOSX/`, `.DS_Store`, and AppleDouble `._*` files.

## Custom Mode

Custom mode is a draft basket for mashup/sample-set creation.

- `Empty draft` starts with no samples.
- `Add files` accepts loose WAVs plus Decent `.dslibrary`, `.zip`, and `.dspreset` sources.
- `Add folder` accepts folders containing WAVs or extracted Decent content.
- Decent sources show selectable groups and individual WAVs, without extracting the whole archive first.
- Candidate WAVs can be auditioned in the selection dialog before staging them.
- Selected WAVs can be staged with a compact row editor:
  - Chromatic maps selected files one-per-key from a chosen start note.
  - Round robins stacks selected files on one root/low note and velocity layer as RR1, RR2, RR3, etc.
  - Velocity layers stacks selected files on one root/low note as Vel 1, Vel 2, Vel 3, etc.
  - `Add all to editor unmapped` bypasses mapping and leaves the rows for manual editor work.
  - Each selected row still exposes preview, `Root`, `Low`, `Vel`, and `RR` controls before adding.
- Multi-select removal only removes items from the draft; it does not delete source files.
- `Save as` chooses an output folder.
- `Save` reuses the remembered custom output folder.

Picker locations are remembered separately for local sample folders, Decent import sources, Decent import outputs, custom source folders, custom output folders, and WAV save-as exports.

## Known Limits

- SFZ import is intentionally out of scope for this pass.
- AIFF/FLAC/OGG conversion is intentionally out of scope; output remains WAV-only.
- Direct NT SD waveform/audio work needs a better device-side file API before it should be reintroduced.
- Drag/drop key assignment is not included yet.

## Suggested Review Focus

- Confirm the Decent import strategy language is accurate enough for users who are not sample-format experts.
- Validate ambiguous Decent libraries with real-world `.dslibrary`, `.zip`, extracted folder, and `.dspreset` examples.
- Check custom draft save behavior on Windows with large source libraries.
- Confirm local/mounted WAV loop metadata and destructive edits remain clearly separated from direct NT SD browsing.
