{ pkgs, config, lib, putter, ... }:

with lib;

let

  cfg = filterAttrs (n: f: f.enable) config.home.file;

  homeDirectory = config.home.homeDirectory;

  fileType = (import lib/file-type.nix {
    inherit homeDirectory lib pkgs;
  }).fileType;

  sourceStorePath = file:
    let
      sourcePath = toString file.source;
      sourceName = config.lib.strings.storeFileName (baseNameOf sourcePath);
    in
      if builtins.hasContext sourcePath
      then file.source
      else builtins.path { path = file.source; name = sourceName; };

  putterStatePath = "${config.xdg.stateHome}/home-manager/putter-state.json";

in

{
  options = {
    home.file = mkOption {
      description = "Attribute set of files to link into the user home.";
      default = {};
      type = fileType "home.file" "{env}`HOME`" homeDirectory;
    };

    home.internal = {
      filePutterConfig = mkOption {
        type = types.package;
        internal = true;
        description = "Putter configuration.";
      };
    };

    home-files = mkOption {
      type = types.package;
      internal = true;
      description = "Package to contain all home files";
    };
  };

  config = {
    assertions = [(
      let
        dups =
          attrNames
            (filterAttrs (n: v: v > 1)
            (foldAttrs (acc: v: acc + v) 0
            (mapAttrsToList (n: v: { ${v.target} = 1; }) cfg)));
        dupsStr = concatStringsSep ", " dups;
      in {
        assertion = dups == [];
        message = ''
          Conflicting managed target files: ${dupsStr}

          This may happen, for example, if you have a configuration similar to

              home.file = {
                conflict1 = { source = ./foo.nix; target = "baz"; };
                conflict2 = { source = ./bar.nix; target = "baz"; };
              }'';
      })
    ];

    lib.file.mkOutOfStoreSymlink = path:
      let
        pathStr = toString path;
        name = hm.strings.storeFileName (baseNameOf pathStr);
      in
        pkgs.runCommandLocal name {} ''ln -s ${escapeShellArg pathStr} $out'';

    # This verifies that the links we are about to create will not
    # overwrite an existing file.
    home.activation.checkLinkTargets = hm.dag.entryBefore ["writeBoundary"] ''
      ${getExe putter} check -v \
        --state-file "${putterStatePath}" \
        ${config.home.internal.filePutterConfig}
    '';

    home.activation.linkGeneration = hm.dag.entryAfter ["writeBoundary"] ''
      ${getExe putter} apply $VERBOSE_ARG -v ''${DRY_RUN:+--dry-run} \
        --state-file "${putterStatePath}" \
        ${config.home.internal.filePutterConfig}
    '';

    home.activation.checkFilesChanged = hm.dag.entryBefore ["linkGeneration"] (
      let
        homeDirArg = escapeShellArg homeDirectory;
      in ''
        function _cmp() {
          if [[ -d $1 && -d $2 ]]; then
            diff -rq "$1" "$2" &> /dev/null
          else
            cmp --quiet "$1" "$2"
          fi
        }
        declare -A changedFiles
      '' + concatMapStrings (v:
        let
          sourceArg = escapeShellArg (sourceStorePath v);
          targetArg = escapeShellArg v.target;
        in ''
          _cmp ${sourceArg} ${homeDirArg}/${targetArg} \
            && changedFiles[${targetArg}]=0 \
            || changedFiles[${targetArg}]=1
        '') (filter (v: v.onChange != "") (attrValues cfg))
      + ''
        unset -f _cmp
      ''
    );

    home.activation.onFilesChange = hm.dag.entryAfter ["linkGeneration"] (
      concatMapStrings (v: ''
        if (( ''${changedFiles[${escapeShellArg v.target}]} == 1 )); then
          if [[ -v DRY_RUN || -v VERBOSE ]]; then
            echo "Running onChange hook for" ${escapeShellArg v.target}
          fi
          if [[ ! -v DRY_RUN ]]; then
            ${v.onChange}
          fi
        fi
      '') (filter (v: v.onChange != "") (attrValues cfg))
    );

    home.internal.filePutterConfig =
      let putter = import ./lib/putter.nix { inherit lib; };
          manifest = putter.mkPutterManifest {
            inherit putterStatePath;
            sourceBaseDirectory = config.home-files;
            targetBaseDirectory = config.home.homeDirectory;
            fileEntries = attrValues cfg;
          };
      in pkgs.writeText "hm-putter.json" manifest;

    # Symlink directories and files that have the right execute bit.
    # Copy files that need their execute bit changed.
    home-files = pkgs.runCommandLocal
      "home-manager-files"
      {
        nativeBuildInputs = [ pkgs.xorg.lndir ];
      }
      (''
        mkdir -p $out

        # Needed in case /nix is a symbolic link.
        realOut="$(realpath -m "$out")"

        function insertFile() {
          local source="$1"
          local relTarget="$2"
          local executable="$3"
          local recursive="$4"

          # If the target already exists then we have a collision. Note, this
          # should not happen due to the assertion found in the 'files' module.
          # We therefore simply log the conflict and otherwise ignore it, mainly
          # to make the `files-target-config` test work as expected.
          if [[ -e "$realOut/$relTarget" ]]; then
            echo "File conflict for file '$relTarget'" >&2
            return
          fi

          # Figure out the real absolute path to the target.
          local target
          target="$(realpath -m "$realOut/$relTarget")"

          # Target path must be within $HOME.
          if [[ ! $target == $realOut* ]] ; then
            echo "Error installing file '$relTarget' outside \$HOME" >&2
            exit 1
          fi

          mkdir -p "$(dirname "$target")"
          if [[ -d $source ]]; then
            if [[ $recursive ]]; then
              mkdir -p "$target"
              lndir -silent "$source" "$target"
            else
              ln -s "$source" "$target"
            fi
          else
            [[ -x $source ]] && isExecutable=1 || isExecutable=""

            # Link the file into the home file directory if possible,
            # i.e., if the executable bit of the source is the same we
            # expect for the target. Otherwise, we copy the file and
            # set the executable bit to the expected value.
            if [[ $executable == inherit || $isExecutable == $executable ]]; then
              ln -s "$source" "$target"
            else
              cp "$source" "$target"

              if [[ $executable == inherit ]]; then
                # Don't change file mode if it should match the source.
                :
              elif [[ $executable ]]; then
                chmod +x "$target"
              else
                chmod -x "$target"
              fi
            fi
          fi
        }
      '' + concatStrings (
        mapAttrsToList (n: v: ''
          insertFile ${
            escapeShellArgs [
              (sourceStorePath v)
              v.target
              (if v.executable == null
               then "inherit"
               else toString v.executable)
              (toString v.recursive)
            ]}
        '') cfg
      ));
  };
}
