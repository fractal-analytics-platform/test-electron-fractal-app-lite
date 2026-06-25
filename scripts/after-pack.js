const fs = require('fs')
const path = require('path')

module.exports = async function (context) {
  if (context.electronPlatformName !== 'linux') return

  const execName = context.packager.executableName
  const bin = path.join(context.appOutDir, execName)
  const realBin = path.join(context.appOutDir, execName + '.bin')

  if (!fs.existsSync(bin)) return

  fs.renameSync(bin, realBin)

  fs.writeFileSync(
    bin,
    `#!/bin/bash\nexec "$(dirname "$0")/${execName}.bin" --no-sandbox "$@"\n`
  )
  fs.chmodSync(bin, '0755')
}
