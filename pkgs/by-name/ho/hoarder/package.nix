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

  script_start = writeShellScript "hoarder-script-start" ''
    set -eu -o pipefail
    PATH="${coreutils}/bin"

    if [[ "$#" -ne 1 || "x$1" = "x--help" ]]; then
      echo "Usage: $0 <web | workers>" >&2
      exit 1
    fi

    CURRENT_DIR="$(dirname "$(realpath "$0")")"
    PATH="$PATH:$CURRENT_DIR/../node_modules/.bin"

    export NODE_ENV=production
    export RELEASE=${version}
    [[ -d "$DATA_DIR" ]]          # Require DATA_DIR to be defined and exist
    [[ -n "$NEXTAUTH_SECRET" ]]   # The NEXTAUTH_SECRET variable must be defined

    if [[ ! -f "$DATA_DIR/db.db" ]]; then
      echo "Migrating $DATA_DIR before starting"
      tsx "$CURRENT_DIR/../db/migrate.ts"
    fi

    if [[ "x$1" = "xweb" ]]; then
      exec "$CURRENT_DIR/../web/apps/web/server.js"
    fi
    if [[ "x$1" = "xworkers" ]]; then
      export NODE_PATH="$CURRENT_DIR/../workers"
      exec tsx "$CURRENT_DIR/../workers/index.ts"
    fi

    echo "Must specify web or workers" >&2
    exit 1
  '';
  script_hoarder_cli = writeShellScript "hoarder-script-cli" ''
    set -eu -o pipefail
    PATH="$PATH:$CURRENT_DIR/../node_modules/.bin"
    exec "$(dirname "$(realpath "$0")")/../cli/dist/index.mjs"
  '';
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
      PATH="$PATH:$PWD/node_modules/.bin"

      echo "Compiling apps/web..."
      pushd apps/web
      next build --experimental-build-mode compile
      popd

      echo "Building apps/cli"
      pushd apps/cli
      vite build
      popd

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/doc/hoarder
      cp README.md LICENSE $out/share/doc/hoarder

      # Copy necessary files into lib/hoarder while keeping the directory structure
      set -x
      echo $SHELL
      LIB_TO_COPY="node_modules apps/web/.next/standalone apps/cli apps/workers packages/db"
      HOARDER_LIB_PATH="$out/lib/hoarder"
      for DIR in $LIB_TO_COPY; do
        mkdir -p "$HOARDER_LIB_PATH/$DIR"
        cp -Lr $DIR/{.,}* "$HOARDER_LIB_PATH/$DIR"
        chmod -R u+w "$HOARDER_LIB_PATH/$DIR"
      done

      # NextJS requires static files are copied in a specific way
      # https://nextjs.org/docs/pages/api-reference/config/next-config-js/output#automatically-copying-traced-files
      cp -r ./apps/web/public "$HOARDER_LIB_PATH/apps/web/.next/standalone/public"
      cp -r ./apps/web/.next/static "$HOARDER_LIB_PATH/apps/web/.next/standalone/static"

      # Copy and modify helper scripts
      for HELPER_SCRIPT in ${./helpers}/*; do
        HELPER_SCRIPT_NAME="$(basename "$HELPER_SCRIPT")"
        gawk -v "lib_path=$HOARDER_LIB_PATH" -v "release=${version}" '
          /^HOARDER_LIB_PATH=/ { print "HOARDER_LIB_PATH=\"" lib_path "\""; next }
          /^RELEASE=/ { print "RELEASE=\"" release "\""; next }
          { print }
        ' "$HELPER_SCRIPT" >"$HOARDER_LIB_PATH/$HELPER_SCRIPT_NAME"
        chmod +x "$HOARDER_LIB_PATH/$HELPER_SCRIPT_NAME"
        patchShebangs "$HOARDER_LIB_PATH/$(basename "$HELPER_SCRIPT")"
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
