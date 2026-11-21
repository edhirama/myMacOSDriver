#!/bin/bash
# Installs an Xcode scheme, "MacDriver (app)", for this package.
#
#   scripts/install_xcode_scheme.sh
#
# Why: Xcode's auto-generated "MacDriverHost" scheme runs the bare executable from DerivedData.
# That binary has no bundle identifier and a fresh ad-hoc signature each build, so macOS never
# matches it to the Accessibility / Screen Recording grants given to MacDriver.app.
#
# The installed scheme builds as usual, then (post-build action) packages the product into the
# signed build/MacDriver.app, and runs and debugs that bundle. Xcode needs an absolute path to the
# bundle, so the scheme is generated per user and per checkout (in xcuserdata, not committed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/.swiftpm/xcode/xcuserdata/$(whoami).xcuserdatad/xcschemes"
mkdir -p "$DIR"
OUT="$DIR/MacDriver (app).xcscheme"

ref() {
  cat <<EOF
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "$1"
               BuildableName = "$1"
               BlueprintName = "$1"
               ReferencedContainer = "container:">
            </BuildableReference>
EOF
}

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <PostActions>
         <ExecutionAction ActionType = "Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction">
            <ActionContent
               title = "Package MacDriver.app"
               scriptText = "&quot;$ROOT/scripts/package_app.sh&quot; &quot;\$BUILT_PRODUCTS_DIR/MacDriverHost&quot; &quot;\$BUILT_PRODUCTS_DIR/driverctl&quot; &gt; &quot;$ROOT/build/xcode-package.log&quot; 2&gt;&amp;1">
               <EnvironmentBuildable>
$(ref MacDriverHost)
               </EnvironmentBuildable>
            </ActionContent>
         </ExecutionAction>
      </PostActions>
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
$(ref MacDriverHost)
         </BuildActionEntry>
         <BuildActionEntry buildForTesting = "NO" buildForRunning = "YES" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "NO">
$(ref driverctl)
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
$(ref DriverCoreTests)
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <PathRunnable runnableDebuggingMode = "0" FilePath = "$ROOT/build/MacDriver.app">
      </PathRunnable>
      <MacroExpansion>
$(ref MacDriverHost)
      </MacroExpansion>
      <CommandLineArguments>
         <CommandLineArgument argument = "--test-ops" isEnabled = "NO">
         </CommandLineArgument>
         <CommandLineArgument argument = "--no-mirror" isEnabled = "NO">
         </CommandLineArgument>
      </CommandLineArguments>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <PathRunnable runnableDebuggingMode = "0" FilePath = "$ROOT/build/MacDriver.app">
      </PathRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
EOF
mkdir -p "$ROOT/build"
echo "Installed: $OUT"
echo "In Xcode, choose the scheme \"MacDriver (app)\" (Product > Scheme), then Run."
echo "Packaging output goes to build/xcode-package.log."
