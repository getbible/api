import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Keep shipped browser libraries in the same dependency graph that npm audit
// and Dependabot inspect. npm ci verifies the source packages' lockfile hashes.
const require = createRequire(import.meta.url);
const destination = fileURLToPath(new URL('../public/vendor/', import.meta.url));
const shipped = fileURLToPath(new URL('../../static/vendor/', import.meta.url));
const check = process.argv.includes('--check');
const files = [
    ['echarts', 'LICENSE', 'ECHARTS-LICENSE'],
    ['echarts', 'NOTICE', 'ECHARTS-NOTICE'],
    ['bootstrap', 'LICENSE', 'BOOTSTRAP-LICENSE'],
    ['echarts', 'dist/echarts.common.min.js', 'echarts.common.min.js'],
    ['bootstrap', 'dist/css/bootstrap.min.css', 'bootstrap.min.css'],
    ['bootstrap', 'dist/js/bootstrap.bundle.min.js', 'bootstrap.bundle.min.js'],
];

async function publish(name, content) {
    const target = join(destination, name);
    if (check) {
        for (const directory of [destination, shipped]) {
            const checked = join(directory, name);
            let actual;
            try {
                actual = await readFile(checked);
            } catch (error) {
                if (error.code !== 'ENOENT') throw error;
            }
            if (!actual?.equals(content)) {
                throw new Error(`${checked} differs from the locked package; run npm run build and commit the vendor assets.`);
            }
        }
    } else {
        await writeFile(target, content);
    }
}

if (!check) await mkdir(destination, { recursive: true });
const checksums = [];
for (const [packageName, source, name] of files) {
    const packageDirectory = dirname(require.resolve(`${packageName}/package.json`));
    const content = await readFile(join(packageDirectory, source));
    await publish(name, content);
    checksums.push({
        path: `${packageName}/${source}`,
        bytes: content.length,
        sha256: createHash('sha256').update(content).digest('hex'),
    });
}
await publish('checksums.json', Buffer.from(`${JSON.stringify(checksums, null, 2)}\n`));
console.log(`${check ? 'Verified' : 'Updated'} ${files.length} vendor files from the locked npm packages.`);
