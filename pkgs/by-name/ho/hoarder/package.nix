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
  version = "0.20.0";

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
      sha256 = "sha256-P5tXuUsv2gO2AzQTEogHk7CbPK7ibGv8BnCz0ypXMlo=";
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
      hash = "sha256-upmdt4j0PYluqPbXQilt2LCFyCJJK0RmBrQEzhf7ZUU=";
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

      mkdir -p $out/lib/hoarder
      cp -r node_modules $out/lib/hoarder/

      mkdir -p $out/lib/hoarder/web
      cp -r ./apps/web/.next/standalone/{.,}* $out/lib/hoarder/web
      chmod -R u+w $out/lib/hoarder/web
      cp -r ./apps/web/public $out/lib/hoarder/web/apps/web/
      cp -r ./apps/web/.next/static $out/lib/hoarder/web/apps/web/.next/

      mkdir -p $out/lib/hoarder/db
      cp -Lr ./packages/db/* $out/lib/hoarder/db

      mkdir -p $out/lib/hoarder/cli
      cp -Lr ./apps/cli/* $out/lib/hoarder/cli

      mkdir -p $out/lib/hoarder/workers
      cp -Lr ./apps/workers/* $out/lib/hoarder/workers

      mkdir -p $out/lib/hoarder/bin
      cp ${script_start} $out/lib/hoarder/bin/start
      cp ${script_hoarder_cli} $out/lib/hoarder/bin/hoarder-cli

      runHook postInstall
    '';

    fixupPhase = ''
      runHook preFixup

      sed -i '1s|^|#!${nodejs}/bin/node\n|' $out/lib/hoarder/web/apps/web/server.js
      chmod +x $out/lib/hoarder/web/apps/web/server.js

      sed -i "1c #!${nodejs}/bin/node" $out/lib/hoarder/cli/dist/index.mjs
      chmod +x $out/lib/hoarder/cli/dist/index.mjs

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
