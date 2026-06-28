# Windows Flutter Workflow

Use a real Windows path for Flutter commands.

Windows Flutter/Dart can fail or produce nonsense analyzer output when launched from the WSL repo path (`\\wsl.localhost\...`). The stable workflow is:

1. Edit and commit in the WSL repo:

   ```text
   /home/nymph/nt_helper
   ```

2. For quick patch checks, copy only the changed source/doc files to the
   Windows build mirror. This avoids WSL/Windows metadata and generated-file
   churn:

   ```bash
   mkdir -p /mnt/c/Users/babyj/nt_helper_winbuild/lib/ui/poly_multisample
   cp /home/nymph/nt_helper/lib/ui/poly_multisample/poly_multisample_builder_screen.dart \
     /mnt/c/Users/babyj/nt_helper_winbuild/lib/ui/poly_multisample/poly_multisample_builder_screen.dart
   ```

3. For a full mirror refresh, use `rsync --no-perms --no-owner --no-group --omit-dir-times`
   and exclude generated output:

   ```bash
   rsync -rlt --delete --no-perms --no-owner --no-group --omit-dir-times \
     --exclude .git \
     --exclude build \
     --exclude .dart_tool \
     --exclude windows/flutter/ephemeral \
     --exclude macos/Flutter/ephemeral \
     /home/nymph/nt_helper/ \
     /mnt/c/Users/babyj/nt_helper_winbuild/
   ```

4. Run Flutter from the Windows mirror:

   ```bash
   /mnt/c/Windows/System32/cmd.exe /c "cd /d C:\Users\babyj\nt_helper_winbuild && C:\Users\babyj\flutter_3.44.0\bin\flutter.bat analyze lib\ui\poly_multisample\poly_multisample_builder_screen.dart"
   ```

5. Build only when requested:

   ```bash
   /mnt/c/Windows/System32/cmd.exe /c "cd /d C:\Users\babyj\nt_helper_winbuild && C:\Users\babyj\flutter_3.44.0\bin\flutter.bat build windows --release"
   ```

6. Copy the built Windows release back to the shared test folder:

   ```bash
   cp -a /mnt/c/Users/babyj/nt_helper_winbuild/build/windows/x64/runner/Release \
     /mnt/c/Users/babyj/nt_helper-build/build/windows/x64/runner/
   ```

Do not run Windows Flutter directly against `\\wsl.localhost\NymphsCore_Lite\home\nymph\nt_helper`.
