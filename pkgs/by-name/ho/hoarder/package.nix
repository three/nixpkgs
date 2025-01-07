{
  lib,
  callPackage,
  stdenv,
  fetchFromGitHub,
  nodejs,
  node-gyp,
  inter,
  python3,
  bash,
  coreutils,
  writeShellScript,
}:
let
  version = "0.21.0";

  pnpm = callPackage ../../../development/tools/pnpm/generic.nix {
    version = "9.0.0-alpha.8";
    hash = "sha256-pDOllWmwA4mpUTUpVvryXR/fQ7VoIT+95ZHDYnTUvDA";
  };
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "hoarder";
    inherit version;

    src = fetchFromGitHub {
      owner = "hoarder-app";
      repo = "hoarder";
      rev = "v${finalAttrs.version}";
      sha256 = "sha256-3xgpiqq+BV0a/OlcQiGDt59fYNF+zP0+HPeBCRiZj48=";
    };

    patches = [
      ./patches/use-local-font.patch
      ./patches/fix-migrations-path.patch
    ];
    postPatch = ''
      ln -s ${inter}/share/fonts/truetype ./apps/landing/app/fonts
      ln -s ${inter}/share/fonts/truetype ./apps/web/app/fonts
    '';

    nativeBuildInputs = [
      python3
      nodejs
      node-gyp
      pnpm.configHook
    ];
    pnpmDeps = pnpm.fetchDeps {
      inherit (finalAttrs) pname version src;
      hash = "sha256-F6iW0rjcD2RUfWptMLpDw1Gfa2mbbzxqY2Ey1lYZTU4=";
    };
    buildPhase = ''
      runHook preBuild

      pushd node_modules/better-sqlite3
      node-gyp rebuild --release
      popd

      export CI=true
      # PATH="$PATH:$PWD/node_modules/.bin"

      echo "Compiling apps/web..."
      pushd apps/web
      pnpm run build
      popd

      echo "Building apps/cli"
      pushd apps/cli
      pnpm run build
      popd

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/doc/hoarder
      cp README.md LICENSE $out/share/doc/hoarder

      # Copy necessary files into lib/hoarder while keeping the directory structure
      set -x
      LIB_TO_COPY="node_modules apps/web/.next/standalone apps/cli/dist apps/workers packages/db packages/shared packages/trpc"
      HOARDER_LIB_PATH="$out/lib/hoarder"
      for DIR in $LIB_TO_COPY; do
        mkdir -p "$HOARDER_LIB_PATH/$DIR"
        cp -a $DIR/{.,}* "$HOARDER_LIB_PATH/$DIR"
        chmod -R u+w "$HOARDER_LIB_PATH/$DIR"
      done

      # NextJS requires static files are copied in a specific way
      # https://nextjs.org/docs/pages/api-reference/config/next-config-js/output#automatically-copying-traced-files
      cp -r ./apps/web/public "$HOARDER_LIB_PATH/apps/web/.next/standalone/public"
      cp -r ./apps/web/.next/static "$HOARDER_LIB_PATH/apps/web/.next/standalone/static"

      # Copy and patch helper scripts
      for HELPER_SCRIPT in ${./helpers}/*; do
        HELPER_SCRIPT_NAME="$(basename "$HELPER_SCRIPT")"
        # gawk -v "lib_path=$HOARDER_LIB_PATH" -v "release=${version}" '
        #   /^HOARDER_LIB_PATH=/ { print "HOARDER_LIB_PATH=\"" lib_path "\""; next }
        #   /^RELEASE=/ { print "RELEASE=\"" release "\""; next }
        #   { print }
        # ' "$HELPER_SCRIPT" >"$HOARDER_LIB_PATH/$HELPER_SCRIPT_NAME"
        cp "$HELPER_SCRIPT" "$HOARDER_LIB_PATH/"
        substituteInPlace "$HOARDER_LIB_PATH/$HELPER_SCRIPT_NAME" \
          --replace "HOARDER_LIB_PATH=" "HOARDER_LIB_PATH=$HOARDER_LIB_PATH" \
          --replace "RELEASE=" "RELEASE=${version}" \
          --replace "NODEJS=" "NODEJS=${nodejs}"
        chmod +x "$HOARDER_LIB_PATH/$HELPER_SCRIPT_NAME"
        patchShebangs "$HOARDER_LIB_PATH/$HELPER_SCRIPT_NAME"
      done

      runHook postInstall
    '';

    fixupPhase = ''
      runHook preFixup

      # sed -i '1s|^|#!${nodejs}/bin/node\n|' $out/lib/hoarder/web/apps/web/server.js
      # chmod +x $out/lib/hoarder/web/apps/web/server.js

      # sed -i "1c #!${nodejs}/bin/node" $out/lib/hoarder/cli/dist/index.mjs
      # chmod +x $out/lib/hoarder/cli/dist/index.mjs

      runHook postFixup
    '';

  meta = {
    homepage = "https://github.com/hoarder-app/hoarder";
    description = "A self-hostable bookmark-everything app with a touch of AI for the data hoarders out there";
    license = lib.licenses.agpl3Only;
    maintainers = [];
    platforms = lib.platforms.linux;
  };
})
