let sqliteModule;

export async function openReadOnlyDatabase(filePath) {
  if (sqliteModule === undefined) {
    try {
      sqliteModule = await import('node:sqlite');
    } catch {
      sqliteModule = null;
    }
  }
  if (!sqliteModule?.DatabaseSync) {
    return { db: null, unsupported: true };
  }
  try {
    return {
      db: new sqliteModule.DatabaseSync(filePath, { readOnly: true }),
      unsupported: false,
    };
  } catch {
    return { db: null, unsupported: false };
  }
}
