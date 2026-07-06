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
  util-linux,
  yq-go,
  pnpm,
  fetchPnpmDeps,
  pnpmConfigHook,
  versionCheckHook,
}:
let
  # pnpm >= 10 intermittently fails to link nested esbuild copies during a
  # parallel install (ERR_PNPM_ENOENT rename race, pnpm/pnpm#10179). pnpm sizes
  # its import worker pool by CPU count, so pinning the install to a single CPU
  # serialises the imports and avoids the race. The original affinity mask is
  # saved in karakeepCpuMask and restored before the build phase so the
  # application builds still use every core.
  pinPnpmInstallToOneCpu = ''
    karakeepCpuMask="$(taskset -cp $$ | sed 's/.*: //')"
    taskset -cp "$(printf '%s' "$karakeepCpuMask" | sed 's/[,-].*//')" $$
  '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "karakeep";
  version = "0.32.0";

  src = fetchFromGitHub {
    owner = "karakeep-app";
    repo = "karakeep";
    # A main-branch commit past the cli/v0.32.0 tag, taken for its pnpm 11
    # upgrade (patchedDependencies and nodeLinker moved to pnpm-workspace.yaml).
    rev = "4af8bb2fd15beff338a791b7a8e0bbf9b72814d6";
    hash = "sha256-H3SRXax+upFf9bHEg2Og9xuDlSnsnlokoWw1Bc89ZUQ=";
  };

  patches = [
    ./patches/use-local-font.patch
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
    util-linux
    yq-go
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
    nativeBuildInputs = [ util-linux ];
    prePnpmInstall = ''
      ${pinPnpmInstallToOneCpu}
      # The single-CPU install decompresses downloads slowly, so give the large
      # tarballs (e.g. @swc/core) more time and fetch fewer at once to avoid
      # pnpm's default 60s fetch timeout aborting them.
      pnpm config set fetch-timeout 600000
      pnpm config set network-concurrency 4
    '';
    fetcherVersion = 4;
    hash = "sha256-/FTfQBuZrQljz5AiEKHLQoX0CJXmSNT0qXIG4K44Xvk=";
  };

  prePnpmInstall = pinPnpmInstallToOneCpu;

  buildPhase = ''
    runHook preBuild

    # Restore the CPU affinity narrowed for the pnpm install (see
    # pinPnpmInstallToOneCpu) so the application builds use every core.
    taskset -cp "$karakeepCpuMask" $$ || true

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
    # Next.js standalone bundle and the cli as a single bundled file). The
    # workers closure covers both, since it depends on @karakeep/db whose
    # production deps include drizzle-kit/tsx for the `migrate` helper.
    #
    # pnpm deploy is unsuitable here: it re-resolves against the network and
    # emits an isolated (.pnpm) layout, but the bundled workers require their
    # transitive dependencies by bare specifier, which only resolve in the flat
    # node_modules produced by node-linker=hoisted. And `pnpm list` cannot help
    # either: on a hoisted install pnpm >= 10 reports the whole shared tree
    # rather than a per-project closure. So we compute the closure straight from
    # the lockfile (see prod-closure.cjs) and delete everything else. The names
    # it prints (e.g. `drizzle-orm`, `@aws-sdk/client-s3`) are exactly the on
    # disk `*` and `@*/*` entries, so they line up and we match them directly.
    keepList="$NIX_BUILD_TOP/karakeep-prod-deps.txt"
    yq -o=json '.' pnpm-lock.yaml \
      | node ${./prod-closure.cjs} apps/workers \
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
