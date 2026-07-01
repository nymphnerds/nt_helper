# Nymphs-Fork Handoff - Current Import Work

This is the single current handoff for this fork. It replaces the older Decent-only notes and describes the state the next developer should start from.

The central goal is one clean **Import** workflow for the Poly Multisample Builder:

- loose WAVs and WAV folders use a simple row-based picker
- Decent Sampler files/libraries use a Decent-aware strategy dialog
- both paths stage a single editable Disting NT Poly Multisample folder
- Save/Save as writes the staged folder later

## Current Fork State

The top-level builder now has one Import path. It accepts:

- loose `.wav` files
- folders of WAV files
- Decent Sampler `.dspreset`
- Decent Sampler `.dslibrary`
- Decent Sampler `.zip`
- extracted Decent Sampler folders

The flow branches internally by source type. Do not bring back a separate top-level Custom button for the same job.

## Compared With Developer Main

Comparison baseline:

```text
upstream/main = thorinside/nt_helper main
fork branch   = nymph-next-fix
fetched       = 2026-07-01
```

Branch status after the three upstream merges and Decent structural-tag pass:

- First upstream sync: `28419624 Merge remote-tracking branch 'upstream/main' into nymph-next-fix`.
- Second upstream sync: `02d08a66 Merge remote-tracking branch 'upstream/main' into nymph-next-fix`.
- Third upstream sync: `55c4fdbc Merge remote-tracking branch 'upstream/main' into nymph-next-fix`.
- Current fork work sits on top of all three syncs and includes the structural Decent tag/import cleanup.

First upstream sync brought in:

```text
118498c3 Bump version to 2.42.0+278
c9a138d3 chore(video): gate popup diagnostics to debug builds
c24dd66e fix(video): avoid reclaiming focus from Windows popup
c90b68f0 fix(video): keep popup activation on top-level HWND
14b8a9b4 fix(video): avoid hidden popup focus activation
f6d9d49a fix(video): avoid stealing focus from Windows popup
aa7e5474 chore(video): log Windows popup focus diagnostics
b2d8a6a5 fix(video): replace Windows popup backend
81d18f5d fix(video): hide Linux popup on close
5aefedf0 fix(video): keep Linux popup close local
076277f7 ci: update flutter version
bb736ce1 build: upgrade flutter midi command
42882f45 feat(video): add opt-in floating popup window
```

Second upstream sync brought in:

```text
d1b137b0 Bump version to 2.42.1+279
5521c736 fix(midi): preserve Windows MIDI discovery after disconnect
```

Third upstream sync brought in:

```text
0588394c Bump version to 2.42.2+280
494a8b60 fix(update): harden Windows updater install script
4fd32d79 fix(update): require platform asset before announcing release
```

Committed fork payload versus the fork point includes:

- `lib/poly_multisample/decent_sampler_converter.dart`
- `lib/poly_multisample/poly_multisample_models.dart`
- `lib/poly_multisample/poly_multisample_parser.dart`
- `lib/poly_multisample/wav_metadata.dart`
- `lib/ui/poly_multisample/poly_multisample_builder_screen.dart`
- `test/poly_multisample/decent_sampler_converter_test.dart`
- `test/poly_multisample/poly_multisample_parser_test.dart`
- `test/poly_multisample/wav_metadata_test.dart`
- `docs/POLYSAMPLER_BUILDER_FORK.md`
- `docs/WINDOWS_FLUTTER_WORKFLOW.md`
- README/pubspec/supporting builder integration changes

Current fork work in this handoff:

- `lib/poly_multisample/decent_sampler_converter.dart`
- `lib/ui/poly_multisample/poly_multisample_builder_screen.dart`
- `test/poly_multisample/decent_sampler_converter_test.dart`
- `README.md`
- `docs/NYMPHS_FORK_HANDOFF.md`

Direct diff from current working tree to `upstream/main` is larger because it includes both the fork feature work and upstream video/Flutter changes that are not merged into this branch yet.

## Loose WAV Import

Loose WAV import is in a good state and should be preserved.

The picker shows one row per WAV:

```text
checkbox | preview | filename | source group | Root | Low | Vel | RR
```

It supports:

- preview before adding
- select all / clear
- quick mapping as Chromatic, Round robins, or Velocity layers
- row-level edit of `Root`, `Low`, `Vel`, and `RR`
- add selected WAVs unmapped
- add all WAVs unmapped for manual editor mapping

The important design win is that quick mapping only seeds values. The user can fix any row before selecting/adding it; selection only decides which rows are added.

Rows must not share the same `Root`/`Low`/`Vel`/`RR` slot. Treat `Root + Low + Vel` as an RR lane, and `Root + Low + RR` as a velocity lane. When a loose WAV row is moved within either lane, shift the intervening rows up or down like an insert/reorder. When a row moves to another lane, close the old lane and only shift the new lane if the target slot is occupied.

After importing/staging samples, the Key Map should scroll around the first mapped note instead of showing empty keyboard space before the instrument. Do not clamp the keyboard range to the first note; the full MIDI range must remain available by scrolling. Auto preview should be on by default and use a clear `Auto preview on/off` button with volume-on/volume-off icons.

## Decent Sampler Import

Decent sources use the dedicated strategy dialog. The dialog should stay Decent-aware and must not fall through into the loose WAV picker after Continue.

Every valid Decent source should show the strategy/options dialog after analysis, even if the analyzer thinks the file is simple. The user still needs the chance to inspect the XML-derived map, choose Add unmapped, or remap rows before staging.

Current structure:

1. Show analysis first.
2. Choose one preset/instrument for this folder.
3. Choose Tags or Groups inside that preset.
4. Choose a mapping mode.
5. Edit selected rows where needed.
6. Continue stages directly from the structured Decent selection.

Rows should look like the actual editor controls:

```text
checkbox | label | count | Low | Root | Vel | RR
```

Do not add a user-facing `High` control. In this workflow `Low` is the switch point/range boundary control, matching how the Disting NT Poly Multisample editor behaves.

Decent tag/group rows now support preview. Keep this: many Decent tags are vague (`raw`, `buzz`, `mic`, `contact`, `release`, etc.), so auditioning the representative source sample is part of the decision workflow.

## Disting NT Constraint

This builder stages one Disting NT Poly Multisample folder. It is not Kontakt and it is not Decent Sampler.

Decent can express UI layers, mic mixes, tone/tape variants, enabled groups, and controller-controlled group volumes. Disting NT cannot reproduce that layer model directly.

So Decent import must turn selected material into one static folder through one of these mappings:

- **Keep Decent map**: show the Decent XML map through Disting fields and preserve compatible XML root, low/switch point, velocity, RR, and loop data.
- **Chromatic**: place selected tags/groups one per key from Root start.
- **Velocity layers**: assign selected tags/groups to `Vel 1`, `Vel 2`, etc. in row order.
- **Round robins**: assign selected tags/groups to `RR1`, `RR2`, etc. in row order.
- **Add unmapped**: add the selected source samples to the editor for manual mapping.

Round robins mode must not export stale velocity overrides. If the original XML has real velocity ranges, preserving those is fine; the RR quick action itself must not create velocity layers.

Keep Decent map must be honest rather than magical. It should show what Decent said and also where Disting cannot behave the same way:

- tag/group tooltips should expose XML note range, explicit velocity ranges, and RR/`seqPosition` summaries
- row notes should describe the actual sample structure, not guessed names or roles
- examples: `1 fixed-pitch sample across G2-A2`, `3 pitched samples, one per key, G2-A2`, `12 samples over 12 roots, C2-B2`, `2 velocity ranges`, `5 RR slots`
- fixed-pitch beds such as tape/noise beds should stay visible when they point at real samples; they are not empty or junk just because the name looks like an effect/source label
- the visible row controls are Disting override controls; they are not a full raw XML editor

## Decent Hierarchy

The real Decent hierarchy from the library scan is:

```text
source/library -> preset/instrument -> tags/layers or XML groups -> samples/regions
```

Preset selection must happen first. If a library has multiple presets, choose one preset for the current folder. To import another preset, run Import again and save another folder.

Tags are usually the musical choice. Groups remain available because some libraries only expose useful structure through XML group names. If Tags and Groups mirror each other, hide the redundant switch and use Tags.

Decent tag/group choices should start unchecked. Do not auto-select material and do not show suggestions about what the user should choose. Decent libraries are too inconsistent for that to be reliable. The dialog should show facts and controls, then let the user preview and select the material explicitly.

Tag names are labels, not truth. Do not make user-facing include/exclude decisions from keywords such as `Dry`, `Tape`, `raw`, `mic`, `room`, `noise`, `release`, or numbered codes. Base the row text and defaults on actual sample structure: root/low notes, velocity ranges, `seqPosition`, fixed-pitch tracking, and sample counts.

Tag/group rows should show:

- checkbox
- preview
- label
- sample count
- Disting mapping controls when applicable: `Low`, `Root`, `Vel`, `RR`

Row text should describe XML/mapping facts only. Tooltips can carry fuller XML evidence. Avoid `Included`, `Not included`, `Suggested`, or baseline-default wording.

Do not sort visible choices by guessed role. Current sorting is sample-count first, then label. That keeps substantial rows visible without pretending labels are comparable across libraries.

## XML Fidelity Rules

Be true to Decent XML where it is compatible with Disting:

- `rootNote` / key center maps to `Root`
- `loNote` / low key maps to `Low`
- explicit velocity ranges become velocity layers when preserving source mapping
- `seqPosition` and related sequencing become `RR`
- loops are preserved
- sample paths are resolved from folders, archives, and libraries

The analyzer now exposes XML mapping summaries on both groups and tags:

- structural summary
- note range
- explicit velocity range summary
- round robin / `seqPosition` summary
- representative preview source path

Do not invent velocity layers for mic positions, tape/tone variants, reverb, room/close, DI/amp, or arbitrary tags. Only explicit Velocity layers mode should force row velocity numbers. Keep Decent map may preserve real XML velocity ranges when they exist.

Switching mapping modes should reset row overrides back to Decent/default values before applying the new quick mapping. This prevents stale values such as V1/V2/V3 remaining after switching to RR mode.

## Library Scan Lessons

Scan root: `/mnt/m/DecentSampler`

Parsed:

- 443 Decent source containers/files
- 620 `.dspreset` presets
- 4263 Decent groups
- 43752 samples
- 37 multi-preset sources
- 363 multi-group presets
- 127 presets with formal XML tags/layers
- 364 presets with explicit velocity ranges
- 112 presets with round robin / sequence positions
- 438 presets with UI/controller bindings

The strongest lesson was preset hierarchy. ASIMOV is the clean example:

- 15 presets
- each preset has one group
- each preset is a separate instrument
- these must not be shown as 15 velocity layers

Controller bindings such as `ENABLED`, `VISIBLE`, `AMP_VOLUME`, and `TAG_VOLUME` usually indicate Decent UI layers/options, not Disting velocity layers.

## Code Landmarks

- Decent converter/analyzer:
  - `lib/poly_multisample/decent_sampler_converter.dart`
- Poly Multisample Builder UI and import dialogs:
  - `lib/ui/poly_multisample/poly_multisample_builder_screen.dart`
- Focused Decent converter tests:
  - `test/poly_multisample/decent_sampler_converter_test.dart`
- This handoff:
  - `docs/NYMPHS_FORK_HANDOFF.md`

## Tests Covering This Work

The focused Decent test file currently covers:

- Decent zip/archive import
- macOS junk filtering
- extracted folder import
- source docs copy/skip
- multi-preset analysis
- duplicate RR repair
- structural banks as velocity layers while preserving RR
- pure RR groups staying RR
- forced tag RR not adding velocity layer names
- Keep Decent map showing/editing selected rows without importing only one colliding layer
- tag XML mapping summaries for note range, velocity ranges, and RR/`seqPosition`
- structure-based tag summaries that do not depend on label names
- fixed-pitch bed tags from real XML (`pitchKeyTrack="0"`) staying visible
- representative preview source paths for Decent tags/groups

## Verification Commands

Run from the Windows build mirror:

```text
C:\Users\babyj\nt_helper_winbuild
```

Commands:

```bash
dart format lib/poly_multisample/decent_sampler_converter.dart lib/ui/poly_multisample/poly_multisample_builder_screen.dart test/poly_multisample/decent_sampler_converter_test.dart
flutter test test/poly_multisample/decent_sampler_converter_test.dart
dart analyze lib/poly_multisample/decent_sampler_converter.dart lib/ui/poly_multisample/poly_multisample_builder_screen.dart test/poly_multisample/decent_sampler_converter_test.dart
flutter build windows --release
```

Latest focused verification before this handoff update:

- `flutter test test/poly_multisample/decent_sampler_converter_test.dart`: passed, 18 tests
- targeted `dart analyze`: passed, no issues
- `git diff --check`: passed
- `flutter build windows --release`: passed

## Failure Modes To Avoid

- Reintroducing a separate top-level Custom entry point.
- Opening a generic WAV picker after Decent strategy Continue.
- Allowing multiple Decent presets in one staged folder.
- Treating separate presets as velocity layers.
- Treating mic/tape/tone/reverb variants as velocity layers by default.
- Hiding row-level `Low`, `Root`, `Vel`, and `RR` controls.
- Adding a `High` control to the import UI.
- Letting a quick mapping mode leave stale overrides from the previous mode.
- Losing preview and per-row mapping in the loose WAV flow.
- Matching tags by loose substrings instead of structured tag keys.

## Current Definition Of Done

This fork is in a clean state when:

- the loose WAV picker remains row-based and previewable
- Decent import starts with analysis and one preset choice
- Tags/Groups appear only where useful
- mapping modes seed simple row values
- rows remain editable through `Low`, `Root`, `Vel`, and `RR`
- RR mode does not export stale velocity overrides
- Keep Decent map preserves compatible XML mapping
- Add unmapped lets the user finish mapping in the editor
- focused Decent tests pass
- targeted analyzer passes
- Windows release build passes
