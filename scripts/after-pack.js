const fs = require('fs')
const path = require('path')

module.exports = async function (context) {
  if (context.electronPlatformName !== 'linux') return

  const bin = path.join(context.appOutDir, 'fractal-electron')
  const realBin = path.join(context.appOutDir, 'fractal-electron.bin')

  if (!fs.existsSync(bin)) return

  fs.renameSync(bin, realBin)

  fs.writeFileSync(
    bin,
    `#!/bin/bash\nexec "$(dirname "$0")/fractal-electron.bin" --no-sandbox "$@"\n`
  )
  fs.chmodSync(bin, '0755')
}
