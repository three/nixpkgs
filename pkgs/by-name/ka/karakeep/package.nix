{
  lib,
  stdenv,
  fetchFromGitHub,
  nix-update-script,
  nixosTests,
  nodejs,
  node-gyp,
  gnutar,
  inter,
  python3,
  srcOnly,
  removeReferencesTo,
  pnpm,
  fetchPnpmDeps,
  pnpmConfigHook,
  versionCheckHook,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "karakeep";
  version = "0.32.0";

  src = fetchFromGitHub {
    owner = "karakeep-app";
    repo = "karakeep";
    tag = "cli/v${finalAttrs.version}";
    hash = "sha256-P88DQi0T7tmBH7cjs8/Hz77bU0oG7u67XPoLsdePNhI=";
  };

  patches = [
    ./patches/use-local-font.patch
    ./patches/dont-lock-pnpm-version.patch
  ];

  postPatch = ''
    ln -s ${inter}/share/fonts/truetype ./apps/web/app/fonts

    substituteInPlace apps/cli/src/commands/dump.ts \
      --replace-fail 'spawn("tar"' 'spawn("${lib.getExe gnutar}"'
  '';

  nativeBuildInputs = [
    python3
    nodejs
    node-gyp
    pnpmConfigHook
    pnpm
  ];

  buildInputs = [
    gnutar
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs)
      pname
      version
      src
      patches
      ;
    inherit pnpm;
    fetcherVersion = 3;
    hash = "";
  };
  buildPhase = ''
    runHook preBuild

    # Based on matrix-appservice-discord
    pushd node_modules/better-sqlite3
    npm run build-release --offline "--nodedir=${srcOnly nodejs}"
    find build -type f -exec ${removeReferencesTo}/bin/remove-references-to -t "${srcOnly nodejs}" {} \;
    popd

    export CI=true

    echo "Compiling apps/web..."
    pushd apps/web
    pnpm run build
    popd

    echo "Building apps/cli"
    pushd apps/cli
    pnpm run build
    popd

    echo "Building apps/workers"
    pushd apps/workers
    pnpm run build
    popd

    runHook postBuild
  '';

  preInstall = ''
    # provide a environment variable to override the cache directory
    # https://github.com/vercel/next.js/discussions/58864
    patch -p1 -i ${./patches/cache-from-env-not-nix-store.patch}
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/doc/karakeep
    cp README.md LICENSE $out/share/doc/karakeep

    KARAKEEP_LIB_PATH="$out/lib/karakeep"

    # Copy necessary files into lib/karakeep while keeping the directory structure
    LIB_TO_COPY="node_modules apps/web/.next/standalone apps/cli/dist apps/workers packages/db packages/shared packages/trpc"
    for DIR in $LIB_TO_COPY; do
      mkdir -p "$KARAKEEP_LIB_PATH/$DIR"
      cp -a $DIR/{.,}* "$KARAKEEP_LIB_PATH/$DIR"
      chmod -R u+w "$KARAKEEP_LIB_PATH/$DIR"
    done

    # Prune node_modules down to the production dependency closure that is
    # actually used at runtime. Only the workers process and the DB migrations
    # resolve modules from this tree (the web app ships as a self-contained
    # Next.js standalone bundle and the cli as a single bundled file). Filtering
    # on the workers package covers both, since it depends on @karakeep/db whose
    # production deps include drizzle-kit/tsx for the `migrate` helper.
    #
    # pnpm deploy is unsuitable here: it re-resolves against the network and
    # emits an isolated (.pnpm) layout, but the bundled workers require their
    # transitive dependencies by bare specifier, which only resolve in the flat
    # node_modules produced by node-linker=hoisted. So instead we compute the
    # production closure with `pnpm list` and delete everything else.
    #
    # `pnpm list --parseable` prints one absolute path per package; the name is
    # whatever follows the final `/node_modules/`, e.g. `drizzle-orm` or the
    # scoped `@aws-sdk/client-s3`. On disk those are exactly the `*` and `@*/*`
    # entries, so the names line up and we can match them directly.
    keepList="$NIX_BUILD_TOP/karakeep-prod-deps.txt"
    pnpm --filter=@karakeep/workers list --prod --depth Infinity --parseable \
      | sed -n 's#.*/node_modules/##p' \
      | sort -u > "$keepList"
    # Bail out rather than wipe everything if the closure came back empty.
    test -s "$keepList"

    (
      cd "$KARAKEEP_LIB_PATH/node_modules"
      shopt -s nullglob
      # Delete every installed package not in the production closure. Unscoped
      # packages are one level down, scoped packages two; either way the name
      # matches the keep-list. Dotfiles (.bin/.pnpm/.modules.yaml) are skipped
      # by the globs, and the @karakeep/* workspace links are always kept.
      printf '%s\n' */ @*/*/ \
        | sed 's#/$##' \
        | awk -v keepfile="$keepList" '
            BEGIN { while ((getline l < keepfile) > 0) keep[l] = 1 }
            /^@[^/]+$/     { next }    # bare scope dir; handled via its children
            /^@karakeep\// { next }    # first-party workspace package: always keep
            !($0 in keep)              # emit packages outside the prod closure
          ' \
        | tr '\n' '\0' | xargs -0 -r rm -rf
      rmdir @*/ 2>/dev/null || true    # drop scope directories left empty
    )

    # NextJS requires static files are copied in a specific way
    # https://nextjs.org/docs/pages/api-reference/config/next-config-js/output#automatically-copying-traced-files
    cp -r ./apps/web/public "$KARAKEEP_LIB_PATH/apps/web/.next/standalone/apps/web/"
    cp -r ./apps/web/.next/static "$KARAKEEP_LIB_PATH/apps/web/.next/standalone/apps/web/.next/"

    # Copy and patch helper scripts
    for HELPER_SCRIPT in ${./helpers}/*; do
      HELPER_SCRIPT_NAME="$(basename "$HELPER_SCRIPT")"
      cp "$HELPER_SCRIPT" "$KARAKEEP_LIB_PATH/"
      substituteInPlace "$KARAKEEP_LIB_PATH/$HELPER_SCRIPT_NAME" \
        --subst-var-by KARAKEEP_LIB_PATH "$KARAKEEP_LIB_PATH" \
        --subst-var-by VERSION "${finalAttrs.version}" \
        --subst-var-by NODEJS "${nodejs}"
      chmod +x "$KARAKEEP_LIB_PATH/$HELPER_SCRIPT_NAME"
      patchShebangs "$KARAKEEP_LIB_PATH/$HELPER_SCRIPT_NAME"
    done

    # The cli should be in bin/
    mkdir -p $out/bin
    mv "$KARAKEEP_LIB_PATH/karakeep" $out/bin/

    runHook postInstall
  '';

  postFixup = ''
    # Remove broken symlinks
    find $out -type l ! -exec test -e {} \; -delete
  '';

  doInstallCheck = true;

  nativeInstallCheckInputs = [
    versionCheckHook
  ];

  passthru = {
    tests = {
      inherit (nixosTests) karakeep;
    };
    updateScript = nix-update-script { };
  };

  meta = {
    homepage = "https://karakeep.app/";
    changelog = "https://github.com/karakeep-app/karakeep/releases/tag/v${finalAttrs.version}";
    description = "Self-hostable bookmark-everything app (links, notes and images) with AI-based automatic tagging and full text search";
    license = lib.licenses.agpl3Only;
    maintainers = [ lib.maintainers.three ];
    mainProgram = "karakeep";
    platforms = lib.platforms.linux;
  };
})
