defmodule Mix.Tasks.Exfuse.Fskit.Provision do
  use Mix.Task

  alias Exfuse.FSKit.Provisioning
  alias Exfuse.FSKit.Signing

  @shortdoc "Mints a development provisioning profile for the FSKit extension"

  @moduledoc """
  Creates the development provisioning profile the FSKit extension needs.

  `com.apple.developer.fskit.fsmodule` is a restricted entitlement: AMFI kills
  the extension at launch unless an embedded provisioning profile authorizes it
  ("Restricted entitlements not validated ... No matching profile found"). A
  trusted signature alone is not enough.

  This task drives Xcode automatic provisioning headlessly: it generates a
  throwaway Xcode project whose target carries the extension bundle id and the
  FSKit entitlements, then runs `xcodebuild -allowProvisioningUpdates
  -allowProvisioningDeviceRegistration`, which registers this Mac as a team
  device, creates/updates the App ID with the FSKit capability, and downloads
  the "Mac Team Provisioning Profile" into the local Xcode profile store —
  where `mix exfuse.fskit.bundle` auto-discovers it.

  Requirements: full Xcode (not just Command Line Tools) with an Apple ID of
  the signing team logged in (Xcode > Settings > Accounts).

      mix exfuse.fskit.provision
      mix exfuse.fskit.provision --team JBX8ZMTT25
  """

  @extension_bundle_id "org.exfuse.fskit.extension"

  @impl true
  def run(args) do
    if :os.type() != {:unix, :darwin} do
      Mix.raise("FSKit provisioning can only run on macOS")
    end

    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [team: :string, sign: :string])

    identity = identity!(opts)
    team = Keyword.get(opts, :team) || team_from_identity!(identity)
    scaffold = scaffold!()

    Mix.shell().info("Requesting FSKit provisioning for #{@extension_bundle_id} (team #{team})")

    xcodebuild!(scaffold, team)

    case Provisioning.find_profile(@extension_bundle_id) do
      {:ok, profile} ->
        Mix.shell().info("Provisioning profile ready: #{profile.name || profile.path}")
        Mix.shell().info(profile.path)

      {:error, reason} ->
        Mix.raise("""
        xcodebuild succeeded but no matching profile was found (#{inspect(reason)}).
        Check ~/Library/Developer/Xcode/UserData/Provisioning Profiles manually.
        """)
    end
  end

  defp identity!(opts) do
    case Signing.resolve_identity(Keyword.get(opts, :sign)) do
      {:ok, "-"} -> Mix.raise("FSKit provisioning needs a trusted identity, not ad-hoc")
      {:ok, identity} -> identity
      {:error, reason} -> Mix.raise("could not resolve signing identity: #{inspect(reason)}")
    end
  end

  defp team_from_identity!(identity) do
    case Provisioning.team_identifier(identity) do
      {:ok, team} ->
        team

      {:error, _reason} ->
        Mix.raise(
          "could not derive the team id from #{inspect(identity)}; pass it with --team TEAMID"
        )
    end
  end

  defp xcodebuild!(scaffold, team) do
    args = [
      "-project",
      Path.join(scaffold, "Provision.xcodeproj"),
      "-scheme",
      "Provision",
      "-configuration",
      "Release",
      "-destination",
      "platform=macOS",
      "-derivedDataPath",
      Path.join(scaffold, "derived"),
      "build",
      "-allowProvisioningUpdates",
      "-allowProvisioningDeviceRegistration",
      "DEVELOPMENT_TEAM=#{team}"
    ]

    case System.cmd("xcodebuild", args, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, status} ->
        errors =
          out
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, "error"))
          |> Enum.join("\n")

        Mix.raise("""
        xcodebuild provisioning failed with status #{status}:

        #{if errors == "", do: String.slice(out, -2000, 2000), else: errors}

        Full Xcode with a logged-in Apple ID of the team is required
        (Xcode > Settings > Accounts).
        """)
    end
  end

  # A minimal app target: automatic provisioning only cares about the platform,
  # bundle id, and entitlements, so a one-file app standing in for the appex is
  # enough to make Xcode register the App ID + device and mint the profile.
  defp scaffold! do
    root = Path.join(System.tmp_dir!(), "exfuse-fskit-provision")
    project = Path.join(root, "Provision.xcodeproj")
    schemes = Path.join(project, "xcshareddata/xcschemes")

    File.rm_rf!(root)
    File.mkdir_p!(schemes)

    File.write!(Path.join(root, "main.swift"), "print(\"exfuse provisioning scaffold\")\n")

    File.cp!(
      Path.join(File.cwd!(), "native/fskit/Entitlements.plist"),
      Path.join(root, "Provision.entitlements")
    )

    File.write!(Path.join(project, "project.pbxproj"), pbxproj())
    File.write!(Path.join(schemes, "Provision.xcscheme"), xcscheme())

    root
  end

  defp pbxproj do
    """
    // !$*UTF8*$!
    {
    	archiveVersion = 1;
    	classes = {
    	};
    	objectVersion = 56;
    	objects = {
    		AA00000000000000000001 /* main.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
    		AA00000000000000000002 /* Provision.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Provision.app; sourceTree = BUILT_PRODUCTS_DIR; };
    		AA00000000000000000003 /* Provision.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Provision.entitlements; sourceTree = "<group>"; };
    		BB00000000000000000001 /* main.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA00000000000000000001; };
    		CC00000000000000000001 /* Sources */ = {
    			isa = PBXSourcesBuildPhase;
    			buildActionMask = 2147483647;
    			files = (
    				BB00000000000000000001,
    			);
    			runOnlyForDeploymentPostprocessing = 0;
    		};
    		DD00000000000000000001 = {
    			isa = PBXGroup;
    			children = (
    				AA00000000000000000001,
    				AA00000000000000000003,
    				DD00000000000000000002,
    			);
    			sourceTree = "<group>";
    		};
    		DD00000000000000000002 /* Products */ = {
    			isa = PBXGroup;
    			children = (
    				AA00000000000000000002,
    			);
    			name = Products;
    			sourceTree = "<group>";
    		};
    		EE00000000000000000001 /* target configs */ = {
    			isa = XCConfigurationList;
    			buildConfigurations = (
    				FF00000000000000000002,
    			);
    			defaultConfigurationIsVisible = 0;
    			defaultConfigurationName = Release;
    		};
    		EE00000000000000000002 /* project configs */ = {
    			isa = XCConfigurationList;
    			buildConfigurations = (
    				FF00000000000000000001,
    			);
    			defaultConfigurationIsVisible = 0;
    			defaultConfigurationName = Release;
    		};
    		FF00000000000000000001 /* Release project */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				SDKROOT = macosx;
    			};
    			name = Release;
    		};
    		FF00000000000000000002 /* Release target */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				CODE_SIGN_ENTITLEMENTS = Provision.entitlements;
    				CODE_SIGN_STYLE = Automatic;
    				ENABLE_HARDENED_RUNTIME = NO;
    				GENERATE_INFOPLIST_FILE = YES;
    				MACOSX_DEPLOYMENT_TARGET = 15.0;
    				PRODUCT_BUNDLE_IDENTIFIER = "#{@extension_bundle_id}";
    				PRODUCT_NAME = Provision;
    				SWIFT_VERSION = 5.0;
    			};
    			name = Release;
    		};
    		GG00000000000000000001 /* Provision */ = {
    			isa = PBXNativeTarget;
    			buildConfigurationList = EE00000000000000000001;
    			buildPhases = (
    				CC00000000000000000001,
    			);
    			buildRules = (
    			);
    			dependencies = (
    			);
    			name = Provision;
    			productName = Provision;
    			productReference = AA00000000000000000002;
    			productType = "com.apple.product-type.application";
    		};
    		HH00000000000000000001 /* Project object */ = {
    			isa = PBXProject;
    			attributes = {
    				LastUpgradeCheck = 1500;
    				TargetAttributes = {
    					GG00000000000000000001 = {
    						CreatedOnToolsVersion = 15.0;
    					};
    				};
    			};
    			buildConfigurationList = EE00000000000000000002;
    			compatibilityVersion = "Xcode 14.0";
    			developmentRegion = en;
    			hasScannedForEncodings = 0;
    			knownRegions = (
    				en,
    				Base,
    			);
    			mainGroup = DD00000000000000000001;
    			productRefGroup = DD00000000000000000002;
    			projectDirPath = "";
    			projectRoot = "";
    			targets = (
    				GG00000000000000000001,
    			);
    		};
    	};
    	rootObject = HH00000000000000000001;
    }
    """
  end

  defp xcscheme do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme LastUpgradeVersion="1500" version="1.7">
      <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
        <BuildActionEntries>
          <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference
              BuildableIdentifier="primary"
              BlueprintIdentifier="GG00000000000000000001"
              BuildableName="Provision.app"
              BlueprintName="Provision"
              ReferencedContainer="container:Provision.xcodeproj">
            </BuildableReference>
          </BuildActionEntry>
        </BuildActionEntries>
      </BuildAction>
      <LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      </LaunchAction>
    </Scheme>
    """
  end
end
