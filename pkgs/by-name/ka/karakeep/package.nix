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
  pnpm_9,
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
    pnpm_9
  ];

  buildInputs = [
    gnutar
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version;
    pnpm = pnpm_9;

    # We need to pass the patched source code, so pnpm sees the patched version
    src = stdenv.mkDerivation {
      name = "${finalAttrs.pname}-patched-source";
      inherit (finalAttrs) src patches;
      installPhase = ''
        cp -pr --reflink=auto -- . $out
      '';
    };

    fetcherVersion = 3;
    hash = "sha256-aT4JPx3iYw4kw8GHXKWMnelSVT0q2S3PK8DgSCQCyKQ=";
  };
  buildPhase = ''
    runHook preBuild

    # Inject workspace packages (copy instead of symlink) so that the
    # `pnpm deploy` in installPhase can assemble a self-contained, production
    # only node_modules for the workers runtime and DB migrations.
    pnpm config set inject-workspace-packages true

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

    # Assemble a production-only node_modules with pnpm deploy instead of
    # shipping the entire monorepo dev install (~2.2 GB). Filtering on the
    # workers package captures everything the runtime actually needs: the
    # workers' production dependency closure plus the injected @karakeep/*
    # workspace packages and their production deps (drizzle-kit/tsx for the
    # DB migrations run by the `migrate` helper). The web app ships as a
    # self-contained Next.js standalone bundle and the cli as a single bundled
    # file, so neither relies on this node_modules.
    # --offline/--frozen-lockfile keep deploy from re-resolving against the
    # network (it otherwise does, since node-linker=hoisted leaves no virtual
    # store to reuse); everything needed is already in the pnpm store.
    pnpmDeployDir="$NIX_BUILD_TOP/karakeep-deploy"
    pnpm deploy --offline --frozen-lockfile \
      --filter=@karakeep/workers --prod "$pnpmDeployDir"

    # Reuse the better-sqlite3 native addon we compiled in buildPhase; the
    # freshly deployed copy comes straight from the store without it.
    cp -a node_modules/better-sqlite3/build/. \
      "$pnpmDeployDir/node_modules/better-sqlite3/build/"

    mkdir -p "$KARAKEEP_LIB_PATH/node_modules"
    cp -a "$pnpmDeployDir"/node_modules/. "$KARAKEEP_LIB_PATH/node_modules/"
    chmod -R u+w "$KARAKEEP_LIB_PATH/node_modules"

    # Copy the build outputs into lib/karakeep while keeping the directory
    # structure. packages/db is needed as the working directory for the
    # `drizzle-kit migrate` invocation in the `migrate` helper.
    LIB_TO_COPY="apps/web/.next/standalone apps/cli/dist apps/workers packages/db packages/shared packages/trpc"
    for DIR in $LIB_TO_COPY; do
      mkdir -p "$KARAKEEP_LIB_PATH/$DIR"
      cp -a $DIR/{.,}* "$KARAKEEP_LIB_PATH/$DIR"
      chmod -R u+w "$KARAKEEP_LIB_PATH/$DIR"
    done

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
