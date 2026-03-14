import RawFileSystemCache from 'next/dist/server/lib/incremental-cache/file-system-cache.js';
const FileSystemCache = RawFileSystemCache.default?.default ?? RawFileSystemCache.default;


export default class CustomCacheHandler extends FileSystemCache {
  constructor(ctx) {
    const customDir = process.env.CACHE_DIRECTORY || ctx.serverDistDir;
    super({
      ...ctx,
      serverDistDir: customDir,
    });
  }
}
